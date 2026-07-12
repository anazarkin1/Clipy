//
//  HistoryMenuSnapshotTests.swift
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

@Suite
struct HistoryMenuSnapshotTests {

    // MARK: - Helpers
    static func presentation() -> HistoryMenuPresentation {
        HistoryMenuPresentation(
            firstListNumber: 1,
            isMarkedWithNumbers: true,
            addsNumericKeyEquivalents: true,
            numberOfItemsPlaceInline: 10,
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

    private func detail(
        id: String,
        title: String,
        ocrText: String? = nil,
        types: [NSPasteboard.PasteboardType] = [.string]
    ) -> PasteboardHistoryDetail {
        PasteboardHistoryDetail(
            history: PasteboardHistory(
                id: .init(rawValue: id),
                title: title,
                ocrText: ocrText,
                pasteboardTypes: types,
                createdAt: 1,
                updateAt: 1,
                deviceID: nil
            ),
            thumbnailAsset: nil
        )
    }

    // MARK: - Ordering & documents
    @Test
    func emptyQueryReturnsAllDetailsInInputOrder() {
        let details = [
            detail(id: "3", title: "gamma"),
            detail(id: "1", title: "alpha"),
            detail(id: "2", title: "beta")
        ]
        let snapshot = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        #expect(snapshot.filteredDetails(matching: "").map(\.history.id) == details.map(\.history.id))
    }

    @Test
    func filteringPreservesInputOrderingAndContainsNoDuplicates() {
        let details = [
            detail(id: "1", title: "swift code"),
            detail(id: "2", title: "python code"),
            detail(id: "3", title: "swift ui"),
            detail(id: "4", title: "rust code")
        ]
        let snapshot = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        let ids = snapshot.filteredDetails(matching: "code").map(\.history.id.rawValue)
        #expect(ids == ["1", "2", "4"])
        #expect(Set(ids).count == ids.count)
    }

    @Test
    func filteringMatchesAcrossTitleOcrAndTypePrefix() {
        let details = [
            detail(id: "1", title: "meeting notes"),
            detail(id: "2", title: "", ocrText: "receipt scan", types: [.png]),
            detail(id: "3", title: "", types: [.pdf])
        ]
        let snapshot = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        #expect(snapshot.filteredDetails(matching: "notes").map(\.history.id.rawValue) == ["1"])
        #expect(snapshot.filteredDetails(matching: "receipt").map(\.history.id.rawValue) == ["2"])
        #expect(snapshot.filteredDetails(matching: "image").map(\.history.id.rawValue) == ["2"])
        #expect(snapshot.filteredDetails(matching: "pdf").map(\.history.id.rawValue) == ["3"])
    }

    @Test
    func documentsAreBuiltForEveryDetail() {
        let details = [detail(id: "1", title: "a"), detail(id: "2", title: "b")]
        let snapshot = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        #expect(snapshot.documentsByID.count == 2)
        #expect(snapshot.documentsByID[.init(rawValue: "1")] != nil)
    }

    @Test
    func lockedOrEmptySnapshotContainsNoSearchDocuments() {
        // A locked/key-unavailable repository returns no details; the snapshot
        // must therefore hold no searchable documents.
        let snapshot = HistoryMenuSnapshot(details: [], presentation: Self.presentation())
        #expect(snapshot.documentsByID.isEmpty)
        #expect(snapshot.filteredDetails(matching: "anything").isEmpty)
    }

    // MARK: - Performance
    @Test(.timeLimit(.minutes(1)))
    func normalizeAndFilterTenThousandHistories() {
        let details = (0..<10_000).map { i in
            detail(
                id: "\(i)",
                title: String(repeating: "lorem ipsum dolor ", count: 14).prefix(256) + " NEEDLE\(i % 7)",
                ocrText: String(repeating: "background text ", count: 64)
            )
        }
        let clock = ContinuousClock()

        let buildDuration = clock.measure {
            _ = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        }
        let snapshot = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        let filterDuration = clock.measure {
            _ = snapshot.filteredDetails(matching: "needle3")
        }

        print("[perf] 10k build(normalize)=\(buildDuration), filter=\(filterDuration)")
        // Recorded baseline (Xcode 26.5, Apple Silicon): build ~60ms, filter
        // ~100ms for 10k rows. The 10k case is the stress fixture and, per the
        // architecture, runs off the main actor behind a 75ms debounce, so the
        // guard here catches gross regressions rather than enforcing the
        // interactive target (which applies to the default small history).
        #expect(filterDuration < .milliseconds(400))
        // Snapshot construction (one-time per data/preference change) bound.
        #expect(buildDuration < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func adversarialMaximumSizeHistories() {
        let details = (0..<1_000).map { i in
            detail(
                id: "\(i)",
                title: String(repeating: "A", count: 10_000) + " token\(i % 5)",
                ocrText: String(repeating: "b", count: 4096)
            )
        }
        let clock = ContinuousClock()
        let snapshot = HistoryMenuSnapshot(details: details, presentation: Self.presentation())
        let filterDuration = clock.measure {
            _ = snapshot.filteredDetails(matching: "token2")
        }
        print("[perf] adversarial 1k max-size filter=\(filterDuration)")
        #expect(filterDuration < .seconds(2))
    }
}
