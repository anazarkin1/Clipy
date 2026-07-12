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

@MainActor
@Suite
struct HistoryMenuSessionControllerTests {

    private let action = #selector(AppDelegate.selectClipMenuItem(_:))

    // MARK: - Test doubles
    /// Captures the scheduled focus block so tests can run it deterministically.
    final class FocusRecorder {
        private(set) var scheduledBlocks: [() -> Void] = []
        func schedule(_ work: @escaping () -> Void) { scheduledBlocks.append(work) }
        func fireAll() {
            let blocks = scheduledBlocks
            scheduledBlocks.removeAll()
            blocks.forEach { $0() }
        }
    }

    /// Captures scheduled debounce work and honors cancellation.
    final class DebounceRecorder {
        final class Entry {
            let work: () -> Void
            var cancelled = false
            init(_ work: @escaping () -> Void) { self.work = work }
        }
        private(set) var entries: [Entry] = []
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

    final class SelectSpy: NSObject {
        private(set) var received: [PasteboardHistory.ID] = []
        @objc func selectClipMenuItem(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? PasteboardHistory.ID {
                received.append(id)
            }
        }
    }

    // MARK: - Fixtures
    private func makeController() -> (HistoryMenuSessionController, FocusRecorder, DebounceRecorder) {
        let focus = FocusRecorder()
        let debounce = DebounceRecorder()
        let controller = HistoryMenuSessionController(
            focusScheduler: { focus.schedule($0) },
            debounceScheduler: { debounce.schedule($0, $1) }
        )
        return (controller, focus, debounce)
    }

    private func presentation(numeric: Bool = false, inline: Int = 20) -> HistoryMenuPresentation {
        HistoryMenuPresentation(
            firstListNumber: 1,
            isMarkedWithNumbers: false,
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

    private func snapshot(_ rows: [(String, String)], numeric: Bool = false, inline: Int = 20) -> HistoryMenuSnapshot {
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
        return HistoryMenuSnapshot(details: details, presentation: presentation(numeric: numeric, inline: inline))
    }

    @discardableResult
    private func install(_ controller: HistoryMenuSessionController, snapshot: HistoryMenuSnapshot, target: AnyObject? = nil) -> NSMenu {
        let menu = NSMenu()
        controller.install(into: menu, snapshot: snapshot, action: action, target: target, folderIcon: nil)
        return menu
    }

    // MARK: - Milestone 0 focus lifecycle
    @Test
    func menuWillOpenSchedulesExactlyOneFocusRequest() {
        let (controller, focus, _) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "a")]))
        controller.menuWillOpen(menu)
        #expect(controller.isMenuOpen)
        #expect(focus.scheduledBlocks.count == 1)
    }

    @Test
    func menuDidCloseCancelsPendingFocusAndClearsQuery() {
        let (controller, focus, _) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "a")]))
        controller.menuWillOpen(menu)
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "hello")
        #expect(controller.query == "hello")

        controller.menuDidClose(menu)
        #expect(!controller.isMenuOpen)
        #expect(controller.query.isEmpty)
        #expect(controller.searchFieldView.query.isEmpty)

        focus.fireAll()
        #expect(controller.performedFocusCount == 0)
    }

    // MARK: - Install & label
    @Test
    func installRendersSearchItemLabelAndUnfilteredHistory() {
        let (controller, _, _) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))

        #expect(menu.items.first === controller.searchMenuItem)
        #expect(menu.items[1] === controller.sectionLabelItem)
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha", "beta"])
        #expect(menu.items.count == 4)
    }

    // MARK: - Query switching
    @Test
    func nonEmptyQueryRendersFilteredSearchResults() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta"), ("3", "gamma")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        debounce.firePending()

        #expect(controller.sectionLabelItem.title == controller.searchResultsLabel)
        #expect(controller.dynamicItems.map(\.title) == ["beta"])
        #expect(menu.items.first === controller.searchMenuItem)
    }

    @Test
    func noMatchShowsSingleDisabledNoMatchesItem() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "zzz")
        debounce.firePending()

        #expect(controller.dynamicItems.count == 1)
        #expect(controller.dynamicItems[0].title == controller.noMatchesLabel)
        #expect(!controller.dynamicItems[0].isEnabled)
        #expect(controller.dynamicItems[0].action == nil)
    }

    @Test
    func clearingRestoresIdenticalUnfilteredStructure() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        debounce.firePending()
        #expect(controller.dynamicItems.map(\.title) == ["beta"])

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "")
        // No debounce fire needed: clearing is synchronous.
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha", "beta"])
    }

    @Test
    func staleDebouncedWorkCannotReplaceRestoredHistory() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)

        // Type a query (schedules debounced work) then clear before it fires.
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "")

        // Firing the stale (cancelled) work must not re-apply the filter.
        debounce.firePending()
        #expect(controller.sectionLabelItem.title == controller.historyLabel)
        #expect(controller.dynamicItems.map(\.title) == ["alpha", "beta"])
    }

    @Test
    func olderSnapshotResultCannotOverwriteNewer() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        // A new snapshot arrives before the debounced work runs.
        controller.updateSnapshot(snapshot([("3", "beta two"), ("4", "delta")]))

        debounce.firePending() // stale generation → ignored
        #expect(controller.dynamicItems.map(\.title) == ["beta two", "delta"])
    }

    @Test
    func queryUpdatesRetainMenuSearchItemAndFieldIdentities() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        controller.menuWillOpen(menu)
        let searchItem = controller.searchMenuItem
        let field = controller.searchFieldView

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        debounce.firePending()

        #expect(controller.searchMenuItem === searchItem)
        #expect(controller.searchFieldView === field)
        #expect(menu.items.first === searchItem)
    }

    // MARK: - Return / Down / numeric shortcuts
    @Test
    func returnInvokesFirstResultExactlyOnce() {
        let (controller, _, debounce) = makeController()
        let spy = SelectSpy()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]), target: spy)
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        debounce.firePending()

        controller.historySearchFieldViewDidCommit(controller.searchFieldView)
        #expect(spy.received == [.init(rawValue: "2")])
    }

    @Test
    func returnDoesNothingWhenNoResults() {
        let (controller, _, debounce) = makeController()
        let spy = SelectSpy()
        let menu = install(controller, snapshot: snapshot([("1", "alpha")]), target: spy)
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "zzz")
        debounce.firePending()

        controller.historySearchFieldViewDidCommit(controller.searchFieldView)
        #expect(spy.received.isEmpty)
    }

    @Test
    func numericShortcutsSuppressedWhileFocusedAndRestoredOnMoveToResults() {
        let (controller, _, _) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")], numeric: true))
        controller.menuWillOpen(menu)

        // While the field is focused, digits must edit text, not trigger shortcuts.
        #expect(controller.numericShortcutsSuppressed)
        #expect(controller.dynamicItems.allSatisfy { $0.keyEquivalent.isEmpty })

        controller.historySearchFieldViewDidRequestMoveToResults(controller.searchFieldView)
        #expect(!controller.numericShortcutsSuppressed)
        #expect(controller.dynamicItems.first?.keyEquivalent == "1")
    }

    // MARK: - Skeleton coexistence
    @Test
    func footerItemsRemainPresentDuringSearch() {
        let (controller, _, debounce) = makeController()
        let menu = install(controller, snapshot: snapshot([("1", "alpha"), ("2", "beta")]))
        // Simulate MenuManager appending snippets/footer after the history section.
        let footer = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")
        menu.addItem(footer)
        controller.menuWillOpen(menu)

        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "beta")
        debounce.firePending()

        #expect(menu.items.last === footer)
        #expect(menu.items.contains(footer))
    }

    @Test
    func installMovesStableItemsToNewMenu() {
        let (controller, _, _) = makeController()
        let menuA = install(controller, snapshot: snapshot([("1", "a")]))
        #expect(menuA.items.contains(controller.searchMenuItem))

        let menuB = install(controller, snapshot: snapshot([("2", "b")]))
        #expect(!menuA.items.contains(controller.searchMenuItem))
        #expect(menuB.items.first === controller.searchMenuItem)
    }
}
