//
//  PasteboardHistoryExtensions.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Shunsuke Furubayashi on 2026/07/05.
//
//  Copyright © 2015-2026 Clipy Project.
//

import AppKit
import Dependencies
import Sharing

extension PasteboardHistory {
    /// The visible type prefix produced for image, PDF, and file histories, or
    /// `nil` for plain text. Exposed so search can match the same caller-facing
    /// string the menu renders.
    var typePrefix: String? {
        let primaryType = pasteboardTypes.first
        if primaryType == .png || primaryType == .tiff || primaryType == .deprecatedTIFF {
            return "(Image)"
        } else if primaryType == .pdf || primaryType == .deprecatedPDF {
            return "(PDF)"
        } else if primaryType == .fileURL || primaryType == .deprecatedFilenames {
            return "(Files)"
        } else {
            return nil
        }
    }

    var typedTitle: String {
        return [typePrefix, title.trimmedMenuTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    var toolTip: String? {
        @Dependency(\.defaultAppStorage) var appStorage

        guard appStorage.bool(forKey: Constants.UserDefaults.showToolTipOnMenuItem) else { return nil }

        let maxLengthOfToolTip = appStorage.integer(forKey: Constants.UserDefaults.maxLengthOfToolTip)
        return String(title.prefix(maxLengthOfToolTip))
    }
}
