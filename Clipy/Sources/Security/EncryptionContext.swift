//
//  EncryptionContext.swift
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

struct EncryptionContext: Equatable {
    let formatVersion: UInt8
    let databaseID: UUID
    let tableName: String
    let columnName: String
    let historyID: String
    let assetID: UUID?
    let assetIndex: Int?
    let pasteboardType: String?
    let thumbnailKind: String?

    init(
        formatVersion: UInt8 = 1,
        databaseID: UUID,
        tableName: String,
        columnName: String,
        historyID: String,
        assetID: UUID? = nil,
        assetIndex: Int? = nil,
        pasteboardType: String? = nil,
        thumbnailKind: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.databaseID = databaseID
        self.tableName = tableName
        self.columnName = columnName
        self.historyID = historyID
        self.assetID = assetID
        self.assetIndex = assetIndex
        self.pasteboardType = pasteboardType
        self.thumbnailKind = thumbnailKind
    }

    var authenticatedData: Data {
        var data = Data()
        data.appendLengthDelimited("formatVersion")
        data.appendLengthDelimited(String(formatVersion))
        data.appendLengthDelimited("databaseID")
        data.appendLengthDelimited(databaseID.uuidString.lowercased())
        data.appendLengthDelimited("tableName")
        data.appendLengthDelimited(tableName)
        data.appendLengthDelimited("columnName")
        data.appendLengthDelimited(columnName)
        data.appendLengthDelimited("historyID")
        data.appendLengthDelimited(historyID)
        data.appendOptionalLengthDelimited("assetID", assetID?.uuidString.lowercased())
        data.appendOptionalLengthDelimited("assetIndex", assetIndex.map(String.init))
        data.appendOptionalLengthDelimited("pasteboardType", pasteboardType)
        data.appendOptionalLengthDelimited("thumbnailKind", thumbnailKind)
        return data
    }
}

private extension Data {
    mutating func appendLengthDelimited(_ string: String) {
        let bytes = Data(string.utf8)
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }

    mutating func appendOptionalLengthDelimited(_ name: String, _ value: String?) {
        appendLengthDelimited(name)
        switch value {
        case .some(let value):
            append(1)
            appendLengthDelimited(value)
        case .none:
            append(0)
        }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
