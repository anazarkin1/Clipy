//
//  HistorySearchMatcherTests.swift
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
struct HistorySearchMatcherTests {

    // MARK: - Helpers
    private func history(
        id: String,
        title: String,
        ocrText: String? = nil,
        types: [NSPasteboard.PasteboardType] = [.string],
        deviceID: String? = "device-1234"
    ) -> PasteboardHistory {
        PasteboardHistory(
            id: .init(rawValue: id),
            title: title,
            ocrText: ocrText,
            pasteboardTypes: types,
            createdAt: 1,
            updateAt: 1,
            deviceID: deviceID
        )
    }

    private func matches(_ text: String, _ history: PasteboardHistory) -> Bool {
        HistorySearchMatcher.matches(
            HistorySearchMatcher.makeQuery(text),
            document: HistorySearchMatcher.makeDocument(history)
        )
    }

    // MARK: - Query emptiness
    @Test
    func emptyWhitespaceAndNewlineQueriesAreEmpty() {
        #expect(HistorySearchMatcher.makeQuery("").isEmpty)
        #expect(HistorySearchMatcher.makeQuery("    ").isEmpty)
        #expect(HistorySearchMatcher.makeQuery("\n\n").isEmpty)
        #expect(HistorySearchMatcher.makeQuery(" \t \n ").isEmpty)
        #expect(!HistorySearchMatcher.makeQuery("a").isEmpty)
    }

    @Test
    func emptyQueryMatchesEverything() {
        let document = HistorySearchMatcher.makeDocument(history(id: "1", title: "anything"))
        #expect(HistorySearchMatcher.matches(HistorySearchMatcher.makeQuery("   "), document: document))
    }

    // MARK: - Normalization
    @Test
    func titleMatchingIsCaseInsensitive() {
        #expect(matches("hello", history(id: "1", title: "HELLO World")))
        #expect(matches("WORLD", history(id: "1", title: "hello world")))
    }

    @Test
    func titleMatchingIsDiacriticInsensitive() {
        #expect(matches("cafe", history(id: "1", title: "Café Latté")))
        #expect(matches("latte", history(id: "1", title: "Café Latté")))
    }

    @Test
    func titleMatchingIsWidthInsensitive() {
        // Full-width Latin letters should match their half-width query.
        #expect(matches("hello", history(id: "1", title: "\u{FF28}\u{FF25}\u{FF2C}\u{FF2C}\u{FF2F}")))
    }

    // MARK: - Fields
    @Test
    func ocrOnlyTextCanMatch() {
        let imageHistory = history(id: "1", title: "", ocrText: "invoice total", types: [.png])
        #expect(matches("invoice", imageHistory))
        #expect(matches("total", imageHistory))
    }

    @Test
    func visibleTypePrefixCanMatch() {
        #expect(matches("image", history(id: "1", title: "", types: [.png])))
        #expect(matches("pdf", history(id: "1", title: "", types: [.pdf])))
        #expect(matches("files", history(id: "1", title: "", types: [.fileURL])))
    }

    // MARK: - AND semantics across fields
    @Test
    func multipleTermsUseAndSemanticsAcrossFields() {
        let history = history(id: "1", title: "report", ocrText: "quarterly numbers", types: [.png])
        // "image" matches the type prefix, "quarterly" matches OCR, "report" the title.
        #expect(matches("report quarterly image", history))
        // Every term must match at least one field.
        #expect(!matches("report missing", history))
    }

    // MARK: - Exclusions
    @Test
    func idsDeviceIdsAndAssetBytesDoNotMatch() {
        let history = history(id: "SECRET-HISTORY-ID", title: "hello", deviceID: "DEVICE-XYZ")
        #expect(!matches("secret", history))
        #expect(!matches("device", history))
        #expect(!matches("xyz", history))
        // Sanity: the title itself still matches.
        #expect(matches("hello", history))
    }

    // MARK: - Full stored text
    @Test
    func fullStoredTitleMatchesBeyondTheShortenedMenuRendering() {
        // A long title whose matching term lives past the truncated menu title.
        let longSuffix = String(repeating: "a", count: 200) + " NEEDLE"
        let history = history(id: "1", title: longSuffix)
        #expect(matches("needle", history))
    }

    // MARK: - Malformed storage
    @Test
    func undecodableTitleProducesNoSearchableText() {
        // Invalid UTF-8 bytes decode to an empty title.
        let malformed = PasteboardHistory(
            id: .init(rawValue: "1"),
            titleData: Data([0xFF, 0xFE, 0xFF]),
            ocrTextData: nil,
            pasteboardTypes: [.string],
            createdAt: 1,
            updateAt: 1,
            deviceID: nil
        )
        let document = HistorySearchMatcher.makeDocument(malformed)
        #expect(document.normalizedFields.isEmpty)
        #expect(!HistorySearchMatcher.matches(HistorySearchMatcher.makeQuery("anything"), document: document))
    }

    // MARK: - Purity / privacy
    @Test
    func creatingDocumentsWritesNothingToUserDefaults() {
        let suiteName = "HistorySearchMatcherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = defaults.dictionaryRepresentation().count
        _ = HistorySearchMatcher.makeDocument(history(id: "1", title: "sensitive query text"))
        _ = HistorySearchMatcher.makeQuery("sensitive query text")
        let after = defaults.dictionaryRepresentation().count
        #expect(before == after)
    }
}
