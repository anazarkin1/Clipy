//
//  HistorySearchMatcher.swift
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

/// A normalized, tokenized search query.
///
/// `normalizedTerms` are produced with a fixed, locale-independent fold so the
/// same input always tokenizes identically regardless of the user's locale.
struct HistorySearchQuery: Equatable, Sendable {
    let originalText: String
    let normalizedTerms: [String]

    /// A query is empty once whitespace/newlines are trimmed and no terms remain.
    var isEmpty: Bool { normalizedTerms.isEmpty }
}

/// The normalized, searchable projection of a single history row.
///
/// Only successfully decoded caller-facing strings become fields. This type is
/// memory-only; it is never persisted, logged, or otherwise written to storage.
struct HistorySearchDocument: Equatable, Sendable {
    let historyID: PasteboardHistory.ID
    let normalizedFields: [String]
    /// The normalized fields joined by a newline, precomputed once so matching
    /// is a single literal search per term. A query term contains no
    /// whitespace, so it can never span the separator — matching the combined
    /// text is therefore equivalent to matching at least one field.
    let combinedText: String

    init(historyID: PasteboardHistory.ID, normalizedFields: [String]) {
        self.historyID = historyID
        self.normalizedFields = normalizedFields
        self.combinedText = normalizedFields.joined(separator: "\n")
    }
}

/// Pure, Foundation-only matching. No SQLite, Keychain, `NSMenu`, UserDefaults,
/// or analytics side effects.
enum HistorySearchMatcher {
    /// Fixed locale so folding/tokenization is deterministic across machines.
    static let foldingLocale = Locale(identifier: "en_US_POSIX")
    static let foldingOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Case-, diacritic-, and width-insensitive normalization using a fixed locale.
    static func normalize(_ text: String) -> String {
        text.folding(options: foldingOptions, locale: foldingLocale)
    }

    /// Builds a query by trimming, splitting on whitespace, and normalizing terms.
    static func makeQuery(_ text: String) -> HistorySearchQuery {
        let terms = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        return HistorySearchQuery(originalText: text, normalizedTerms: terms)
    }

    /// Builds a document from explicit caller-facing fields.
    static func makeDocument(id: PasteboardHistory.ID, fields: [String]) -> HistorySearchDocument {
        let normalized = fields
            .map(normalize)
            .filter { !$0.isEmpty }
        return HistorySearchDocument(historyID: id, normalizedFields: normalized)
    }

    /// Builds a document from a decoded domain history.
    ///
    /// Searchable fields are the full stored title (not the shortened menu
    /// rendering), OCR text when present, and the visible type prefix. Raw asset
    /// bytes, IDs, device IDs, thumbnails, and snippets are intentionally excluded.
    static func makeDocument(_ history: PasteboardHistory) -> HistorySearchDocument {
        var fields: [String] = [history.title]
        if let ocrText = history.ocrText {
            fields.append(ocrText)
        }
        if let typePrefix = history.typePrefix {
            fields.append(typePrefix)
        }
        return makeDocument(id: history.id, fields: fields)
    }

    /// AND semantics: every query term must be a substring of at least one
    /// field. Different terms may match different fields on the same document.
    static func matches(_ query: HistorySearchQuery, document: HistorySearchDocument) -> Bool {
        guard !query.isEmpty else { return true }
        // Both haystack and terms are already folded, so a literal (non-canonical)
        // search is correct and considerably faster than Character-based contains.
        let haystack = document.combinedText
        return query.normalizedTerms.allSatisfy { term in
            haystack.range(of: term, options: .literal) != nil
        }
    }
}
