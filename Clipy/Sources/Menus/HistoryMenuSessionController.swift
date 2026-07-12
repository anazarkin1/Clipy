//
//  HistoryMenuSessionController.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import AppKit

/// A cancellable handle for a scheduled debounce.
final class HistoryMenuDebounceToken {
    private var cancelHandler: (() -> Void)?
    init(cancel: @escaping () -> Void) { self.cancelHandler = cancel }
    func cancel() {
        cancelHandler?()
        cancelHandler = nil
    }
}

/// Owns the search field lifecycle and the dynamic history section for a single
/// history-bearing menu.
///
/// A controller is created per menu (main and history-only) and retained by
/// `MenuManager`. `NSMenu.delegate` is weak, so the controller must be strongly
/// held for the lifetime of its menu.
///
/// The controller keeps the search item, the section-label item, and the search
/// field editor stable across query and snapshot changes; only the dynamic
/// history items are removed and re-inserted, so the tracking `NSMenu`, its
/// field editor, and any marked-text (IME) composition survive updates.
final class HistoryMenuSessionController: NSObject {

    // MARK: - Types
    /// Schedules a focus request to run inside the menu tracking run loop.
    typealias FocusScheduler = (@escaping () -> Void) -> Void
    /// Schedules debounced work; returns a token that cancels it.
    typealias DebounceScheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> HistoryMenuDebounceToken

    // MARK: - Constants
    /// Non-empty query debounce, per the plan.
    static let debounceInterval: TimeInterval = 0.075

    // MARK: - Stable UI
    let searchFieldView: HistorySearchFieldView
    /// The stable search item whose `view` hosts the search field.
    let searchMenuItem = NSMenuItem()
    /// The stable disabled History / Search Results label.
    let sectionLabelItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    // MARK: - Dependencies
    private let focusScheduler: FocusScheduler
    private let debounceScheduler: DebounceScheduler

    // MARK: - Menu / render state
    private(set) weak var menu: NSMenu?
    private(set) var snapshot: HistoryMenuSnapshot?
    private var action: Selector?
    private var target: AnyObject?
    private var folderIcon: NSImage?
    /// The dynamic history items currently installed, tracked by identity.
    private(set) var dynamicItems: [NSMenuItem] = []

    // MARK: - Session state
    private(set) var isMenuOpen = false
    private(set) var query = ""
    /// Bumped on every open/close; cancels a stale scheduled focus request.
    private(set) var sessionGeneration = 0
    /// Bumped on every query change; rejects stale debounced work.
    private(set) var queryGeneration = 0
    /// Bumped on every snapshot update; rejects results built from an old snapshot.
    private(set) var snapshotGeneration = 0
    /// While the field holds focus, numeric key equivalents are suppressed so
    /// digits edit the query instead of triggering history shortcuts.
    private(set) var numericShortcutsSuppressed = true
    private var pendingDebounce: HistoryMenuDebounceToken?

    // MARK: - Coordination hooks
    /// Invoked from `menuWillOpen` so the owner can refresh the snapshot as a
    /// final consistency check before the menu is shown.
    var onMenuWillOpen: ((HistoryMenuSessionController) -> Void)?
    /// Invoked from `menuDidClose` so the owner can apply a deferred skeleton
    /// rebuild that was suppressed while the menu was tracking.
    var onMenuDidClose: ((HistoryMenuSessionController) -> Void)?

    // Test-observable counters.
    private(set) var scheduledFocusCount = 0
    private(set) var performedFocusCount = 0

    // MARK: - Localized labels
    var historyLabel: String { String(localized: "History") }
    var searchResultsLabel: String { String(localized: "Search Results") }
    var noMatchesLabel: String { String(localized: "No Matching History") }

    // MARK: - Initialize
    init(
        searchFieldView: HistorySearchFieldView = HistorySearchFieldView(),
        focusScheduler: @escaping FocusScheduler = HistoryMenuSessionController.defaultFocusScheduler,
        debounceScheduler: @escaping DebounceScheduler = HistoryMenuSessionController.defaultDebounceScheduler
    ) {
        self.searchFieldView = searchFieldView
        self.focusScheduler = focusScheduler
        self.debounceScheduler = debounceScheduler
        super.init()
        self.searchFieldView.delegate = self
        self.searchMenuItem.view = searchFieldView
    }

    static func defaultFocusScheduler(_ work: @escaping () -> Void) {
        RunLoop.current.perform(inModes: [.eventTracking, .default]) { work() }
    }

    static func defaultDebounceScheduler(_ delay: TimeInterval, _ work: @escaping () -> Void) -> HistoryMenuDebounceToken {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in work() }
        // Deliver even while the menu is tracking.
        RunLoop.current.add(timer, forMode: .eventTracking)
        RunLoop.current.add(timer, forMode: .default)
        return HistoryMenuDebounceToken { timer.invalidate() }
    }

    // MARK: - Installation
    /// Installs the search item, section label, and rendered (unfiltered)
    /// history items into `menu`, becoming its delegate. Called whenever the
    /// menu skeleton is rebuilt. The caller appends snippets/footer afterwards.
    func install(
        into menu: NSMenu,
        snapshot: HistoryMenuSnapshot,
        action: Selector,
        target: AnyObject? = nil,
        folderIcon: NSImage? = nil
    ) {
        detachStableItems()
        removeDynamicItems(from: self.menu)

        self.menu = menu
        self.snapshot = snapshot
        self.action = action
        self.target = target
        self.folderIcon = folderIcon
        self.snapshotGeneration &+= 1
        menu.delegate = self

        menu.addItem(searchMenuItem)
        menu.addItem(sectionLabelItem)
        // Rebuilds start with an empty query and suppressed numeric shortcuts.
        query = ""
        numericShortcutsSuppressed = true
        renderResults(for: "")
    }

    /// Replaces the current snapshot (e.g. after a history/preference change)
    /// and reapplies the active query in place, preserving focus.
    func updateSnapshot(_ snapshot: HistoryMenuSnapshot) {
        self.snapshot = snapshot
        self.snapshotGeneration &+= 1
        pendingDebounce?.cancel()
        pendingDebounce = nil
        renderResults(for: searchFieldView.query)
    }

    /// Clears the query, field text, normalized search state, pending work, and
    /// rendered results in response to a protected-state (lock / key-unavailable
    /// / error) transition. The encryption feature owns the placeholder shown in
    /// the menu; this method only guarantees that no stale query or result
    /// survives the transition. Assign an empty snapshot via `updateSnapshot` to
    /// drop all normalized documents from memory.
    func clearForProtectedState() {
        snapshotGeneration &+= 1
        queryGeneration &+= 1
        pendingDebounce?.cancel()
        pendingDebounce = nil
        clearQuery()
        numericShortcutsSuppressed = true
        if snapshot != nil {
            renderResults(for: "")
        }
    }

    // MARK: - Rendering
    private func renderResults(for text: String) {
        guard let menu, let snapshot, let action else { return }
        let searchQuery = HistorySearchMatcher.makeQuery(text)
        sectionLabelItem.title = searchQuery.isEmpty ? historyLabel : searchResultsLabel

        var presentation = snapshot.presentation
        if numericShortcutsSuppressed {
            presentation.addsNumericKeyEquivalents = false
        }
        let renderer = HistoryMenuRenderer(
            presentation: presentation,
            action: action,
            target: target,
            folderIcon: presentation.showsFolderIcon ? folderIcon : nil
        )

        let details = snapshot.filteredDetails(matching: searchQuery)
        let items: [NSMenuItem]
        if !searchQuery.isEmpty && details.isEmpty {
            items = [renderer.makeNoMatchesItem(title: noMatchesLabel)]
        } else {
            items = renderer.makeHistoryItems(details)
        }
        replaceDynamicItems(with: items, in: menu)
    }

    private func replaceDynamicItems(with items: [NSMenuItem], in menu: NSMenu) {
        removeDynamicItems(from: menu)
        dynamicItems = items
        let labelIndex = menu.index(of: sectionLabelItem)
        guard labelIndex >= 0 else { return }
        var insertAt = labelIndex + 1
        for item in items {
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
    }

    private func removeDynamicItems(from menu: NSMenu?) {
        guard let menu else { dynamicItems = []; return }
        for item in dynamicItems where item.menu === menu {
            menu.removeItem(item)
        }
        dynamicItems = []
    }

    private func detachStableItems() {
        searchMenuItem.menu?.removeItem(searchMenuItem)
        sectionLabelItem.menu?.removeItem(sectionLabelItem)
    }

    // MARK: - Query
    func applyQuery(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queryGeneration &+= 1
        let generation = queryGeneration
        let snapshotGen = snapshotGeneration
        pendingDebounce?.cancel()
        pendingDebounce = nil

        let searchQuery = HistorySearchMatcher.makeQuery(text)
        if searchQuery.isEmpty {
            // Clearing bypasses the debounce and restores History immediately.
            renderResults(for: text)
            return
        }
        pendingDebounce = debounceScheduler(Self.debounceInterval) { [weak self] in
            guard let self,
                  self.isMenuOpen,
                  self.queryGeneration == generation,
                  self.snapshotGeneration == snapshotGen else { return }
            self.renderResults(for: text)
        }
    }

    // MARK: - Focus
    private func scheduleFocus() {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        scheduledFocusCount += 1
        focusScheduler { [weak self] in
            guard let self, self.isMenuOpen, self.sessionGeneration == generation else { return }
            self.performedFocusCount += 1
            self.searchFieldView.focusSearchField()
        }
    }

    private func clearQuery() {
        query = ""
        searchFieldView.reset()
    }

    // MARK: - Result activation
    /// The first activatable history item (top-level or inside the first folder).
    func firstResultItem() -> NSMenuItem? {
        for item in dynamicItems {
            if item.action != nil && item.representedObject != nil {
                return item
            }
            if let submenu = item.submenu,
               let nested = submenu.items.first(where: { $0.action != nil && $0.representedObject != nil }) {
                return nested
            }
        }
        return nil
    }
}

// MARK: - NSMenuDelegate
extension HistoryMenuSessionController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        pendingDebounce?.cancel()
        pendingDebounce = nil
        clearQuery()
        numericShortcutsSuppressed = true
        renderResults(for: "")
        // Final consistency check: let the owner refresh the snapshot with the
        // latest history/preferences before the menu is shown.
        onMenuWillOpen?(self)
        scheduleFocus()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        sessionGeneration &+= 1
        queryGeneration &+= 1
        pendingDebounce?.cancel()
        pendingDebounce = nil
        clearQuery()
        // Apply any menu-skeleton rebuild that was deferred while tracking.
        onMenuDidClose?(self)
    }
}

// MARK: - HistorySearchFieldViewDelegate
extension HistoryMenuSessionController: HistorySearchFieldViewDelegate {
    func historySearchFieldView(_ view: HistorySearchFieldView, didChangeQuery query: String) {
        applyQuery(query)
    }

    func historySearchFieldViewDidCommit(_ view: HistorySearchFieldView) {
        // Return activates the first result exactly once; if there is no result,
        // it does nothing and leaves the menu open.
        guard let item = firstResultItem(), let action = item.action, item.isEnabled else { return }
        NSApp.sendAction(action, to: item.target, from: item)
        menu?.cancelTracking()
    }

    func historySearchFieldViewDidRequestMoveToResults(_ view: HistorySearchFieldView) {
        // Restore numeric shortcuts and hand navigation to the result list.
        guard numericShortcutsSuppressed else { return }
        numericShortcutsSuppressed = false
        renderResults(for: searchFieldView.query)
        highlightFirstResult()
    }

    func historySearchFieldViewDidCancel(_ view: HistorySearchFieldView) {
        // Clear the field text (the cancel button also does this in production)
        // and restore History immediately, bypassing the debounce.
        searchFieldView.query = ""
        applyQuery("")
    }

    private func highlightFirstResult() {
        guard let menu, let first = dynamicItems.first(where: { $0.isEnabled && !$0.isSeparatorItem }) else { return }
        let selector = Selector(("highlightItem:"))
        guard menu.responds(to: selector) else { return }
        menu.perform(selector, with: first)
    }
}
