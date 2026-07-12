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

/// Owns the search field lifecycle for a single history-bearing menu.
///
/// A controller is created per menu (main and history-only) and retained by
/// `MenuManager`. `NSMenu.delegate` is weak, so the controller must be strongly
/// held for the lifetime of its menu.
///
/// Milestone 0 scope: prove that focus can be requested on `menuWillOpen`
/// without activating the application and cancelled on `menuDidClose`, using
/// only public AppKit APIs. Filtering and in-place rendering arrive in later
/// milestones.
final class HistoryMenuSessionController: NSObject {

    // MARK: - Types
    /// Schedules a focus request to run inside the menu tracking run loop.
    /// Injectable so tests can capture and control execution deterministically.
    typealias FocusScheduler = (@escaping () -> Void) -> Void

    // MARK: - Properties
    let searchFieldView: HistorySearchFieldView
    private let focusScheduler: FocusScheduler
    /// The menu currently owning this controller (weak: `NSMenu.delegate` is weak).
    private(set) weak var menu: NSMenu?
    /// The stable search item whose `view` hosts the search field.
    let searchMenuItem = NSMenuItem()

    private(set) var isMenuOpen = false
    /// Monotonic generation bumped on every open/close; used to cancel a
    /// scheduled focus request that is no longer valid.
    private(set) var sessionGeneration = 0
    /// Trimmed, current query text for this session.
    private(set) var query = ""

    // Test-observable counters.
    private(set) var scheduledFocusCount = 0
    private(set) var performedFocusCount = 0

    // MARK: - Initialize
    init(
        searchFieldView: HistorySearchFieldView = HistorySearchFieldView(),
        focusScheduler: @escaping FocusScheduler = HistoryMenuSessionController.defaultFocusScheduler
    ) {
        self.searchFieldView = searchFieldView
        self.focusScheduler = focusScheduler
        super.init()
        self.searchFieldView.delegate = self
        self.searchMenuItem.view = searchFieldView
    }

    // MARK: - Attach
    /// Installs the stable search item at the top of `menu` and becomes its
    /// delegate. Called each time the menu skeleton is rebuilt.
    func attach(to menu: NSMenu) {
        menu.delegate = self
        if searchMenuItem.menu !== menu {
            searchMenuItem.menu?.removeItem(searchMenuItem)
            menu.insertItem(searchMenuItem, at: 0)
        }
        self.menu = menu
    }

    /// Default scheduler: run the focus request inside the event-tracking run
    /// loop mode so it fires while the menu is open.
    static func defaultFocusScheduler(_ work: @escaping () -> Void) {
        RunLoop.current.perform(inModes: [.eventTracking, .default]) {
            work()
        }
    }

    // MARK: - Query handling
    private func updateQuery(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearQuery() {
        query = ""
        searchFieldView.reset()
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
}

// MARK: - NSMenuDelegate
extension HistoryMenuSessionController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        clearQuery()
        scheduleFocus()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        // Bumping the generation cancels any still-pending focus request.
        sessionGeneration &+= 1
        clearQuery()
    }
}

// MARK: - HistorySearchFieldViewDelegate
extension HistoryMenuSessionController: HistorySearchFieldViewDelegate {
    func historySearchFieldView(_ view: HistorySearchFieldView, didChangeQuery query: String) {
        updateQuery(query)
    }

    func historySearchFieldViewDidCommit(_ view: HistorySearchFieldView) {
        // Return handling is implemented in a later milestone.
    }

    func historySearchFieldViewDidRequestMoveToResults(_ view: HistorySearchFieldView) {
        // Down-arrow navigation is implemented in a later milestone.
    }

    func historySearchFieldViewDidCancel(_ view: HistorySearchFieldView) {
        clearQuery()
    }
}
