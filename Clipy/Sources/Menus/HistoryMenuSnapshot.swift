//
//  HistoryMenuSnapshot.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import Foundation

/// Immutable presentation preferences captured once per snapshot.
///
/// The renderer receives these explicitly and must not read UserDefaults, so a
/// preference change mid-render can never split a single list across two
/// configurations.
struct HistoryMenuPresentation: Equatable {
    /// 0 when list numbering starts at zero, otherwise 1.
    var firstListNumber: Int
    var isMarkedWithNumbers: Bool
    var addsNumericKeyEquivalents: Bool
    var maxKeyEquivalents: Int
    var numberOfItemsPlaceInline: Int
    var numberOfItemsPlaceInsideFolder: Int
    var showsImage: Bool
    var showsColorPreview: Bool
    var showsFolderIcon: Bool
    var thumbnailWidth: Int
    var thumbnailHeight: Int
    var showsToolTip: Bool
    var maxLengthOfToolTip: Int

    init(
        firstListNumber: Int,
        isMarkedWithNumbers: Bool,
        addsNumericKeyEquivalents: Bool,
        maxKeyEquivalents: Int = 10,
        numberOfItemsPlaceInline: Int,
        numberOfItemsPlaceInsideFolder: Int,
        showsImage: Bool,
        showsColorPreview: Bool,
        showsFolderIcon: Bool,
        thumbnailWidth: Int,
        thumbnailHeight: Int,
        showsToolTip: Bool,
        maxLengthOfToolTip: Int
    ) {
        self.firstListNumber = firstListNumber
        self.isMarkedWithNumbers = isMarkedWithNumbers
        self.addsNumericKeyEquivalents = addsNumericKeyEquivalents
        self.maxKeyEquivalents = maxKeyEquivalents
        self.numberOfItemsPlaceInline = numberOfItemsPlaceInline
        self.numberOfItemsPlaceInsideFolder = numberOfItemsPlaceInsideFolder
        self.showsImage = showsImage
        self.showsColorPreview = showsColorPreview
        self.showsFolderIcon = showsFolderIcon
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.showsToolTip = showsToolTip
        self.maxLengthOfToolTip = maxLengthOfToolTip
    }
}

/// One immutable snapshot of the history menu's data and presentation.
///
/// History is fetched and decoded/decrypted only when a snapshot is
/// constructed. Filtering operates entirely against this in-memory value and
/// must not hit SQLite, Keychain, OCR, or thumbnail decoding per keystroke.
struct HistoryMenuSnapshot: Equatable {
    let details: [PasteboardHistoryDetail]
    let documentsByID: [PasteboardHistory.ID: HistorySearchDocument]
    let presentation: HistoryMenuPresentation

    init(details: [PasteboardHistoryDetail], presentation: HistoryMenuPresentation) {
        self.details = details
        self.presentation = presentation
        var documents: [PasteboardHistory.ID: HistorySearchDocument] = [:]
        documents.reserveCapacity(details.count)
        for detail in details {
            documents[detail.history.id] = HistorySearchMatcher.makeDocument(detail.history)
        }
        self.documentsByID = documents
    }

    /// Details matching `query`, preserving the snapshot's ordering.
    ///
    /// An empty query returns the full, unfiltered list.
    func filteredDetails(matching query: HistorySearchQuery) -> [PasteboardHistoryDetail] {
        guard !query.isEmpty else { return details }
        return details.filter { detail in
            guard let document = documentsByID[detail.history.id] else { return false }
            return HistorySearchMatcher.matches(query, document: document)
        }
    }

    /// Convenience: filter using raw query text.
    func filteredDetails(matching text: String) -> [PasteboardHistoryDetail] {
        filteredDetails(matching: HistorySearchMatcher.makeQuery(text))
    }
}
