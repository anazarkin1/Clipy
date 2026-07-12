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

    /// Captures the scheduled focus block so tests can run it deterministically.
    final class FocusRecorder {
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

    private func makeController() -> (HistoryMenuSessionController, FocusRecorder) {
        let recorder = FocusRecorder()
        let controller = HistoryMenuSessionController(
            focusScheduler: { recorder.schedule($0) }
        )
        return (controller, recorder)
    }

    @Test
    func menuWillOpenSchedulesExactlyOneFocusRequest() {
        let (controller, recorder) = makeController()
        let menu = NSMenu()
        menu.delegate = controller

        controller.menuWillOpen(menu)

        #expect(controller.isMenuOpen)
        #expect(controller.scheduledFocusCount == 1)
        #expect(recorder.scheduledBlocks.count == 1)
    }

    @Test
    func menuDidCloseCancelsPendingFocusAndClearsQuery() {
        let (controller, recorder) = makeController()
        let menu = NSMenu()
        menu.delegate = controller

        controller.menuWillOpen(menu)
        // Simulate the user typing before the scheduled focus fires.
        controller.searchFieldView.query = "hello"
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "hello")
        #expect(controller.query == "hello")

        controller.menuDidClose(menu)
        #expect(!controller.isMenuOpen)
        #expect(controller.query.isEmpty)
        #expect(controller.searchFieldView.query.isEmpty)

        // The still-pending focus block must be a no-op after close.
        recorder.fireAll()
        #expect(controller.performedFocusCount == 0)
    }

    @Test
    func focusRequestRunsWhileMenuIsOpen() {
        let (controller, recorder) = makeController()
        let menu = NSMenu()
        menu.delegate = controller

        controller.menuWillOpen(menu)
        recorder.fireAll()

        // Without a hosting window the field cannot become first responder,
        // but the request must have executed while the menu was open.
        #expect(controller.performedFocusCount == 1)
    }

    @Test
    func queryIsTrimmedOfWhitespace() {
        let (controller, _) = makeController()
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "  spaced  ")
        #expect(controller.query == "spaced")
    }

    @Test
    func cancelClearsQuery() {
        let (controller, _) = makeController()
        controller.searchFieldView.query = "text"
        controller.historySearchFieldView(controller.searchFieldView, didChangeQuery: "text")
        #expect(controller.query == "text")

        controller.historySearchFieldViewDidCancel(controller.searchFieldView)
        #expect(controller.query.isEmpty)
        #expect(controller.searchFieldView.query.isEmpty)
    }
}
