//
//  HistoryMenuSessionControllerTests.swift
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
import Testing
@testable import Clipy

// MARK: - Test doubles

/// Captures the scheduled focus block so tests can run it deterministically.
private final class FocusRecorder {
    private(set) var scheduledBlocks: [() -> Void] = []

    func schedule(_ work: @escaping () -> Void) {
        scheduledBlocks.append(work)
    }

    func fireAll() {
        let blocks = scheduledBlocks
        scheduledBlocks.removeAll()
        blocks.forEach { $0() }
    }
}

/// Captures scheduled debounce work and honors cancellation.
private final class DebounceRecorder {
    private final class Entry {
        let work: () -> Void
        var cancelled = false

        init(_ work: @escaping () -> Void) {
            self.work = work
        }
    }

    private var entries: [Entry] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> HistoryMenuDebounceToken {
        let entry = Entry(work)
        entries.append(entry)
        return HistoryMenuDebounceToken { entry.cancelled = true }
    }

    /// Fire every not-yet-cancelled scheduled block.
    func firePending() {
        entries.filter { !$0.cancelled }.forEach { $0.work() }
    }
}

/// Bundles the two recorders so the controller factory returns a small tuple.
private final class Recorders {
    let focus = FocusRecorder()
    let debounce = DebounceRecorder()
}

private final class SelectSpy: NSObject {
    private(set) var received: [PasteboardHistory.ID] = []

    @objc func selectClipMenuItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? PasteboardHistory.ID {
            received.append(id)
        }
    }
}

// MARK: - Suite

@MainActor
@Suite
struct HistoryMenuSessionControllerTests {

    private let action = #selector(AppDelegate.selectClipMenuItem(_:))

    fileprivate func makeController() -> (HistoryMenuSessionController, Recorders) {
        let recorders = Recorders()
        let controller = HistoryMenuSessionController(
            focusScheduler: { recorders.focus.schedule($0) },
            debounceScheduler: { recorders.debounce.schedule($0, $1) }
        )
        return (controller, recorders)
    }

    fileprivate func presentation(numeric: Bool = false, inline: Int = 20, marked: Bool = false) -> HistoryMenuPresentation {
        HistoryMenuPresentation(
            firstListNumber: 1,
            isMarkedWithNumbers: marked,
            addsNumericKeyEquivalents: numeric,
            numberOfItemsPlaceInline: inline,
            numberOfItemsPlaceInsideFolder: 10,
            showsImage: false,
            showsColorPreview: false,
            showsFolderIcon: false,
            thumbnailWidth: 20,
            thumbnailHeight: 20,
            showsToolTip: false,
            maxLengthOfToolTip: 100
        )
    }

    fileprivate func snapshot(_ rows: [(String, String)], numeric: Bool = false, inline: Int = 20, marked: Bool = false) -> HistoryMenuSnapshot {
        let details = rows.map { id, title in
            PasteboardHistoryDetail(
                history: PasteboardHistory(
                    id: .init(rawValue: id),
                    title: title,
                    ocrText: nil,
                    pasteboardTypes: [.string],
                    createdAt: 1,
                    updateAt: 1,
                    deviceID: nil
                ),
                thumbnailAsset: nil
            )
        }
        return HistoryMenuSnapshot(details: details, presentation: presentation(numeric: numeric, inline: inline, marked: marked))
    }

    /// Simulates real typing: updates the field editor value and notifies the delegate.
    fileprivate func type(_ controller: HistoryMenuSessionController, _ text: String) {
        controller.searchFieldView.query = text
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: text)
    }

    @discardableResult
    fileprivate func install(_ controller: HistoryMenuSessionController, snapshot: HistoryMenuSnapshot, target: AnyObject? = nil) -> NSMenu {
        let menu = NSMenu()
        controller.install(into: menu, snapshot: snapshot, action: action, target: target, folderIcon: nil)
        return menu
    }
}

// MARK: - Focus lifecycle (Milestone 0)

extension HistoryMenuSessionControllerTests {
    @Test
    func menuWillOpenSchedulesExactlyOneFocusRequest() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "a")]))

        controller.menuWillOpen(menu)

        #expect(controller.isMenuOpen)
        #expect(recorders.focus.scheduledBlocks.count == 1)
    }

    @Test
    func menuDidCloseCancelsPendingFocusAndClearsQuery() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "a")]))

        controller.menuWillOpen(menu)
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "hello")
        #expect(controller.query == "hello")

        controller.menuDidClose(menu)
        #expect(!controller.isMenuOpen)
        #expect(controller.query.isEmpty)
        #expect(controller.searchFieldView.query.isEmpty)

        recorders.focus.fireAll()
        #expect(controller.performedFocusCount == 0)
    }
}

// MARK: - Install & query switching (Milestone 3)

extension HistoryMenuSessionControllerTests {
    @Test
    func installRendersSearchItemLabelAndUnfilteredHistory() {
        let (controller, _) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))

        #expect(menu.items.first === controller.searchMenuItem)
        #expect(menu.items[1] === controller.sectionLabelItem)
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha", "beta"])
        #expect(menu.items.count == 4)
    }

    @Test
    func nonEmptyQueryRendersFilteredSearchResults() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta"), ("3", "gamma")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        recorders.debounce.firePending()

        #expect(controller.sectionLabelItem.title == controller.searchResultsLabel)
        #expect(controller.dynamicItems.map(\.title) == ["beta"])
        #expect(menu.items.first === controller.searchMenuItem)
    }

    @Test
    func noMatchShowsSingleDisabledNoMatchesItem() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "zzz")
        recorders.debounce.firePending()

        #expect(controller.dynamicItems.count == 1)
        #expect(controller.dynamicItems[0].title == controller.noMatchesLabel)
        #expect(!controller.dynamicItems[0].isEnabled)
        #expect(controller.dynamicItems[0].action == nil)
    }

    @Test
    func clearingRestoresIdenticalUnfilteredStructure() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        recorders.debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta"])

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "")
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha", "beta"])
    }

    @Test
    func staleDebouncedWorkCannotReplaceRestoredHistory() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "")

        recorders.debounce.firePending()
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha", "beta"])
    }

    @Test
    func olderSnapshotResultCannotOverwriteNewer() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        controller.updateSnapshot(snapshot([("3", "beta two"), ("4", "delta")]))

        recorders.debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta two", "delta"])
    }

    @Test
    func queryUpdatesRetainMenuSearchItemAndFieldIdentities() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)
        let searchItem = controller.searchMenuItem
        let field = controller.searchFieldView

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        recorders.debounce.firePending()

        #expect(controller.searchMenuItem === searchItem)
        #expect(controller.searchFieldView === field)
        #expect(menu.items.first === searchItem)
    }

    @Test
    func returnInvokesFirstResultExactlyOnce() {
        let (controller, recorders) = makeController()
        let spy = SelectSpy()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]), target: spy)
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        recorders.debounce.firePending()

        controller.historySearchFieldViewDidCommit(controller.searchFieldView)
        #expect(spy.received == [.init(rawValue: "2")])
    }

    @Test
    func returnDoesNothingWhenNoResults() {
        let (controller, recorders) = makeController()
        let spy = SelectSpy()
        let menu = install(controller, snapshot: snapshot([("1", "alpha")]), target: spy)
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "zzz")
        recorders.debounce.firePending()

        controller.historySearchFieldViewDidCommit(controller.searchFieldView)
        #expect(spy.received.isEmpty)
    }

    @Test
    func numericShortcutsSuppressedWhileFocusedAndRestoredOnMoveToResults() {
        let (controller, _) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")], numeric: true))
        controller.menuWillOpen(menu)

        #expect(controller.numericShortcutsSuppressed)
        #expect(controller.dynamicItems.allSatisfy { $0.keyEquivalent.isEmpty })

        controller.historySearchFieldViewDidRequestMoveToResults(controller.searchFieldView)
        #expect(!controller.numericShortcutsSuppressed)
        #expect(controller.dynamicItems.first?.keyEquivalent == "1")
    }

    @Test
    func footerItemsRemainPresentDuringSearch() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        let footer = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")
        menu.addItem(footer)
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        recorders.debounce.firePending()

        #expect(menu.items.last === footer)
        #expect(menu.items.contains(footer))
    }

    @Test
    func installMovesStableItemsToNewMenu() {
        let (controller, _) = makeController()
        let menuA = install(controller, snapshot: snapshot([("1", "a")]))
        #expect(menuA.items.contains(controller.searchMenuItem))

        let menuB = install(controller, snapshot: snapshot([("2", "b")]))
        #expect(!menuA.items.contains(controller.searchMenuItem))
        #expect(menuB.items.first === controller.searchMenuItem)
    }
}

// MARK: - Live data / preferences / protected state (Milestone 4)

extension HistoryMenuSessionControllerTests {
    @Test
    func updateSnapshotReappliesActiveQueryPreservingIdentities() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)
        type(controller, "beta")
        recorders.debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta"])

        let searchItem = controller.searchMenuItem
        let field = controller.searchFieldView
        controller.updateSnapshot(snapshot([("1", "alpha"), ("2", "beta"), ("3", "beta two")]))

        #expect(controller.dynamicItems.map(\.title) == ["beta", "beta two"])
        #expect(controller.sectionLabelItem.title == controller.searchResultsLabel)
        #expect(controller.searchMenuItem === searchItem)
        #expect(controller.searchFieldView === field)
        #expect(menu.items.first === searchItem)
    }

    @Test
    func deletedResultDisappearsThenClearingShowsUpdatedHistory() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)
        type(controller, "beta")
        recorders.debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta"])

        controller.updateSnapshot(snapshot([("1", "alpha")]))
        #expect(controller.dynamicItems.count == 1)
        #expect(controller.dynamicItems[0].title == controller.noMatchesLabel)

        type(controller, "")
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha"])
    }

    @Test
    func preferenceChangeReappliesCurrentQueryWithNewPresentation() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")], marked: false))
        controller.menuWillOpen(menu)
        type(controller, "beta")
        recorders.debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta"])

        controller.updateSnapshot(snapshot([("1", "alpha"), ("2", "beta")], marked: true))
        #expect(controller.dynamicItems.map(\.title) == ["1. beta"])
    }

    @Test
    func menuLifecycleHooksFire() {
        let (controller, _) = makeController()
        var willOpen = 0
        var didClose = 0
        controller.onMenuWillOpen = { _ in willOpen += 1 }
        controller.onMenuDidClose = { _ in didClose += 1 }
        let menu = install(controller, snapshot: snapshot([("1", "a")]))

        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)
        #expect(willOpen == 1)
        #expect(didClose == 1)
    }

    @Test
    func clearForProtectedStateClearsQueryDocumentsAndResults() {
        let (controller, recorders) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)
        type(controller, "beta")
        recorders.debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta"])

        controller.clearForProtectedState()
        #expect(controller.query.isEmpty)
        #expect(controller.searchFieldView.query.isEmpty)

        controller.updateSnapshot(snapshot([]))
        #expect(controller.dynamicItems.isEmpty)
        #expect(controller.snapshot?.documentsByID.isEmpty == true)
    }
}

// MARK: - Localization / accessibility (Milestone 5)

extension HistoryMenuSessionControllerTests {
    @Test
    func localizedSectionLabelsAreDistinctAndNonEmpty() {
        let (controller, _) = makeController()
        #expect(!controller.historyLabel.isEmpty)
        #expect(!controller.searchResultsLabel.isEmpty)
        #expect(!controller.noMatchesLabel.isEmpty)
        #expect(controller.historyLabel != controller.searchResultsLabel)
        #expect(controller.searchResultsLabel != controller.noMatchesLabel)
    }

    @Test
    func searchFieldReportsNoMarkedTextByDefault() {
        let (controller, _) = makeController()
        #expect(!controller.searchFieldView.hasMarkedText)
    }
}
