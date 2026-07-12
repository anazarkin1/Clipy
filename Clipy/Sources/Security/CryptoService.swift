//
//  CryptoService.swift
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
import CryptoKit
import Foundation
import SQLiteData

struct CryptoService {
    let keyID: UUID
    let databaseID: UUID
    private let crypto: HistoryCrypto

    init?(database: Database) throws {
        guard case let .unlocked(keyID, keyData) = HistorySecurityBootstrap.startupState else {
            return nil
        }
        guard let modeString = try #sql(
            """
            SELECT "mode"
            FROM "historySecurityMetadata"
            WHERE "id" = 1
            """,
            as: String.self
        )
        .fetchOne(database),
              HistorySecurityMode(rawValue: modeString) == .encrypted else {
            return nil
        }
        guard let keyIDString = try #sql(
            """
            SELECT "keyID"
            FROM "historySecurityMetadata"
            WHERE "id" = 1
            """,
            as: String?.self
        )
        .fetchOne(database).flatMap({ $0 }),
              UUID(uuidString: keyIDString) == keyID else {
            return nil
        }
        guard let databaseIDString = try #sql(
            """
            SELECT "databaseID"
            FROM "historySecurityMetadata"
            WHERE "id" = 1
            """,
            as: String.self
        )
        .fetchOne(database),
              let databaseID = UUID(uuidString: databaseIDString) else {
            return nil
        }
        self.keyID = keyID
        self.databaseID = databaseID
        self.crypto = HistoryCrypto(rootKey: SymmetricKey(data: keyData), databaseID: databaseID)
    }

    func historyID(for content: PasteboardContent) -> PasteboardHistory.ID {
        PasteboardHistory.ID(rawValue: crypto.fingerprintID(for: content.canonicalData))
    }

    func sealHistoryTitle(_ data: Data, historyID: PasteboardHistory.ID) throws -> Data {
        try seal(data, table: "pasteboardHistories", column: "titleData", historyID: historyID)
    }

    func openHistoryTitle(_ data: Data, historyID: PasteboardHistory.ID) throws -> Data {
        try open(data, table: "pasteboardHistories", column: "titleData", historyID: historyID)
    }

    func sealHistoryOCR(_ data: Data, historyID: PasteboardHistory.ID) throws -> Data {
        try seal(data, table: "pasteboardHistories", column: "ocrTextData", historyID: historyID)
    }

    func openHistoryOCR(_ data: Data, historyID: PasteboardHistory.ID) throws -> Data {
        try open(data, table: "pasteboardHistories", column: "ocrTextData", historyID: historyID)
    }

    func sealAsset(_ data: Data, asset: PasteboardHistoryAsset) throws -> Data {
        try crypto.seal(
            data,
            context: EncryptionContext(
                databaseID: databaseID,
                tableName: "pasteboardHistoryAssets",
                columnName: "data",
                historyID: asset.pasteboardHistoryID.rawValue,
                assetID: asset.id.rawValue,
                assetIndex: asset.index,
                pasteboardType: asset.pasteboardType.rawValue
            )
        )
    }

    func openAsset(_ asset: PasteboardHistoryAsset) throws -> Data {
        try crypto.open(
            asset.data,
            context: EncryptionContext(
                databaseID: databaseID,
                tableName: "pasteboardHistoryAssets",
                columnName: "data",
                historyID: asset.pasteboardHistoryID.rawValue,
                assetID: asset.id.rawValue,
                assetIndex: asset.index,
                pasteboardType: asset.pasteboardType.rawValue
            )
        )
    }

    func sealThumbnail(_ thumbnail: PasteboardHistoryThumbnailAsset) throws -> Data {
        try crypto.seal(
            thumbnail.data,
            context: EncryptionContext(
                databaseID: databaseID,
                tableName: "pasteboardHistoryThumbnailAssets",
                columnName: "data",
                historyID: thumbnail.pasteboardHistoryID.rawValue,
                thumbnailKind: thumbnail.kind.rawValue
            )
        )
    }

    func openThumbnail(_ thumbnail: PasteboardHistoryThumbnailAsset) throws -> Data {
        try crypto.open(
            thumbnail.data,
            context: EncryptionContext(
                databaseID: databaseID,
                tableName: "pasteboardHistoryThumbnailAssets",
                columnName: "data",
                historyID: thumbnail.pasteboardHistoryID.rawValue,
                thumbnailKind: thumbnail.kind.rawValue
            )
        )
    }

    private func seal(
        _ data: Data,
        table: String,
        column: String,
        historyID: PasteboardHistory.ID
    ) throws -> Data {
        try crypto.seal(
            data,
            context: EncryptionContext(
                databaseID: databaseID,
                tableName: table,
                columnName: column,
                historyID: historyID.rawValue
            )
        )
    }

    private func open(
        _ data: Data,
        table: String,
        column: String,
        historyID: PasteboardHistory.ID
    ) throws -> Data {
        try crypto.open(
            data,
            context: EncryptionContext(
                databaseID: databaseID,
                tableName: table,
                columnName: column,
                historyID: historyID.rawValue
            )
        )
    }
}
