//
//  PasteboardHistoryRepositoryEncryptionTests.swift
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
import Dependencies
import DependenciesTestSupport
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite(
    .serialized,
    .dependencies {
        try $0.bootstrapDatabase()
    }
)
struct EncryptedHistoryRepositoryTests {
    @Dependency(\.defaultDatabase)
    var database

    let repository = PasteboardHistoryRepository()

    @Test
    func encryptedSaveFetchRoundTripsAndStoresNoPlaintext() throws {
        let fixture = try enableEncryptedHistory()
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(
            PasteboardContent(
                assets: [
                    PasteboardContent.Asset(type: .string, data: Data("Secret Marker 123".utf8)),
                    PasteboardContent.Asset(type: .rtf, data: Data("Second Secret Payload".utf8)),
                    PasteboardContent.Asset(type: .pdf, data: Data("PDF Secret Payload".utf8)),
                    PasteboardContent.Asset(type: .URL, data: Data("https://clipy-app.com/secret".utf8)),
                    PasteboardContent.Asset(type: .fileURL, data: Data("/tmp/secret-file.txt".utf8))
                ]
            )
        )
        let encryptedID = try historyID(for: content)

        repository.save(id: PasteboardHistory.ID(rawValue: content.hash), content: content, updateAt: 10)
        repository.updateOCRText(id: encryptedID, ocrText: "OCR Secret Marker")

        let history = try #require(repository.fetchHistory(id: encryptedID))
        #expect(history.title == "Secret Marker 123")
        #expect(history.ocrText == "OCR Secret Marker")
        #expect(history.pasteboardTypes == [.string, .rtf, .pdf, .URL, .fileURL])
        #expect(repository.fetchContent(id: encryptedID) == content)

        let rawHistory = try rawHistory(id: encryptedID)
        #expect(rawHistory.id == encryptedID)
        #expect(rawHistory.id.rawValue != content.hash)
        #expect(rawHistory.titleData.range(of: Data("Secret Marker 123".utf8)) == nil)
        #expect(rawHistory.ocrTextData?.range(of: Data("OCR Secret Marker".utf8)) == nil)
        let storedAssets = try rawAssets(id: encryptedID)
        #expect(storedAssets.allSatisfy { asset in
            asset.data.range(of: Data("Secret".utf8)) == nil
        })
        #expect(fixture.keyID == HistorySecurityBootstrap.startupState.keyID)
    }

    @Test
    func encryptedImageAndColorThumbnailsRoundTripWithoutRawPlaintext() throws {
        _ = try enableEncryptedHistory()
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let imageContent = try #require(
            PasteboardContent(image: NSImage.create(with: .blue, size: NSSize(width: 20, height: 20)))
        )
        let colorContent = try #require(PasteboardContent("#ff0000"))
        let imageID = try historyID(for: imageContent)
        let colorID = try historyID(for: colorContent)

        repository.save(id: PasteboardHistory.ID(rawValue: imageContent.hash), content: imageContent, updateAt: 1)
        repository.save(id: PasteboardHistory.ID(rawValue: colorContent.hash), content: colorContent, updateAt: 2)

        #expect(repository.fetchContent(id: imageID) == imageContent)
        #expect(repository.fetchContent(id: colorID) == colorContent)

        let details = repository.fetchHistoryDetails(
            sortsByCreatedAt: false,
            includesThumbnailAsset: true,
            limit: 10
        )
        let imageThumbnail = try #require(details.first { $0.history.id == imageID }?.thumbnailAsset)
        let colorThumbnail = try #require(details.first { $0.history.id == colorID }?.thumbnailAsset)
        let rawImageThumbnail = try #require(try rawThumbnail(id: imageID))
        let rawColorThumbnail = try #require(try rawThumbnail(id: colorID))

        #expect(imageThumbnail.kind == .image)
        #expect(colorThumbnail.kind == .colorCode)
        #expect(rawImageThumbnail.data != imageThumbnail.data)
        #expect(rawColorThumbnail.data != colorThumbnail.data)
        #expect(repository.fetchHistory(id: colorID)?.title == "#ff0000")
    }

    @Test
    func encryptedIDIsHMACNotLegacySHAHash() throws {
        _ = try enableEncryptedHistory()
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(PasteboardContent("same visible text"))
        let legacyID = PasteboardHistory.ID(rawValue: content.hash)
        let encryptedID = try historyID(for: content)

        repository.save(id: legacyID, content: content, updateAt: 1)

        #expect(encryptedID != legacyID)
        #expect(repository.fetchHistory(id: legacyID) == nil)
        #expect(repository.fetchHistory(id: encryptedID)?.title == "same visible text")
        #expect(try rawHistoryIDs() == [encryptedID.rawValue])
    }

    @Test
    func unlockedStateDoesNotEncryptPlaintextMetadataDatabase() throws {
        HistorySecurityBootstrap.startupState = .unlocked(
            keyID: UUID(),
            keyData: Data(repeating: 0x5a, count: 32)
        )
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(PasteboardContent("plaintext metadata"))
        let legacyID = PasteboardHistory.ID(rawValue: content.hash)

        repository.save(id: legacyID, content: content, updateAt: 1)

        #expect(repository.fetchHistory(id: legacyID)?.title == "plaintext metadata")
        #expect(try rawHistoryIDs() == [legacyID.rawValue])
    }

    @Test
    func blockedEncryptedStatesRejectHistoryOperations() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(PasteboardContent("blocked secret"))
        let legacyID = PasteboardHistory.ID(rawValue: content.hash)
        let states: [HistoryLockState] = [
            .locked(keyID: UUID()),
            .keyMissing(keyID: UUID()),
            .keyUnavailable(keyID: UUID()),
            .blockedByOrphanKeys([UUID()]),
            .transitioning(.enablingCleanup),
            .corrupt("bad metadata")
        ]

        for state in states {
            HistorySecurityBootstrap.startupState = state
            repository.save(id: legacyID, content: content, updateAt: 1)
            repository.updateOCRText(id: legacyID, ocrText: "blocked ocr")

            #expect(repository.fetchHistory(id: legacyID) == nil)
            #expect(repository.fetchContent(id: legacyID) == nil)
            #expect(repository.fetchHistoryDetails(sortsByCreatedAt: false, includesThumbnailAsset: true, limit: 10) == [])
            #expect(try rawHistoryIDs() == [])
        }
    }

    @Test
    func tamperedEncryptedAssetFailsClosed() throws {
        _ = try enableEncryptedHistory()
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(PasteboardContent("tamper secret"))
        let encryptedID = try historyID(for: content)
        repository.save(id: PasteboardHistory.ID(rawValue: content.hash), content: content, updateAt: 1)

        try database.write { database in
            let asset = try #require(
                try PasteboardHistoryAsset
                    .where { $0.pasteboardHistoryID.eq(encryptedID) }
                    .fetchOne(database)
            )
            var tamperedData = asset.data
            tamperedData[tamperedData.startIndex] ^= 0xff
            try PasteboardHistoryAsset
                .find(asset.id)
                .update { $0.data = #bind(tamperedData) }
                .execute(database)
        }

        #expect(repository.fetchContent(id: encryptedID) == nil)
    }

    @Test
    func timestampRefreshDoesNotReencryptExistingPayloadsOrLoseOCR() throws {
        _ = try enableEncryptedHistory()
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(PasteboardContent("refresh secret"))
        let encryptedID = try historyID(for: content)

        repository.save(id: PasteboardHistory.ID(rawValue: content.hash), content: content, updateAt: 1)
        repository.updateOCRText(id: encryptedID, ocrText: "recognized encrypted text")
        let firstAssetData = try rawAssets(id: encryptedID).map(\.data)
        let firstOCRData = try #require(rawHistory(id: encryptedID).ocrTextData)

        repository.save(id: PasteboardHistory.ID(rawValue: content.hash), content: content, updateAt: 2)

        #expect(try rawAssets(id: encryptedID).map(\.data) == firstAssetData)
        #expect(try rawHistory(id: encryptedID).ocrTextData == firstOCRData)
        #expect(repository.fetchHistory(id: encryptedID)?.updateAt == 2)
        #expect(repository.fetchHistory(id: encryptedID)?.ocrText == "recognized encrypted text")
        #expect(repository.fetchContent(id: encryptedID) == content)
    }

    @Test(.timeLimit(.minutes(1)))
    func observerDoesNotPublishStaleDecryptedRowsAfterLock() async throws {
        let fixture = try enableEncryptedHistory()
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let content = try #require(PasteboardContent("observer secret"))
        let encryptedID = try historyID(for: content)
        var publishedHistories = [[PasteboardHistory]]()
        let cancellable = repository.observeHistories().sink { value in
            publishedHistories.append(value)
        }
        defer { _ = cancellable }

        try await waitUntil { publishedHistories.count >= 1 }
        repository.save(id: PasteboardHistory.ID(rawValue: content.hash), content: content, updateAt: 1)
        try await waitUntil {
            publishedHistories.last?.map(\.id) == [encryptedID]
        }

        HistorySecurityBootstrap.startupState = .locked(keyID: fixture.keyID)
        repository.deleteHistory(id: encryptedID)
        try await waitUntil {
            publishedHistories.last == []
        }
    }
}

private extension EncryptedHistoryRepositoryTests {
    struct EncryptedHistoryFixture {
        let keyID: UUID
        let databaseID: UUID
        let keyData: Data
    }

    func enableEncryptedHistory() throws -> EncryptedHistoryFixture {
        let fixture = EncryptedHistoryFixture(
            keyID: UUID(),
            databaseID: UUID(),
            keyData: Data((0..<32).map(UInt8.init))
        )
        let keyCheck = HistoryKeyCheck.make(
            rootKey: fixture.keyData,
            keyID: fixture.keyID,
            databaseID: fixture.databaseID
        )

        try database.write { database in
            try #sql(
                """
                UPDATE "historySecurityMetadata"
                SET
                  "mode" = 'encrypted',
                  "databaseID" = \(bind: fixture.databaseID.uuidString),
                  "keyID" = \(bind: fixture.keyID.uuidString),
                  "keyCheck" = \(bind: keyCheck)
                WHERE "id" = 1
                """
            )
            .execute(database)
        }
        HistorySecurityBootstrap.startupState = .unlocked(keyID: fixture.keyID, keyData: fixture.keyData)
        return fixture
    }

    func historyID(for content: PasteboardContent) throws -> PasteboardHistory.ID {
        try database.read { database in
            let cryptoService = try #require(try CryptoService(database: database))
            return cryptoService.historyID(for: content)
        }
    }

    func rawHistory(id: PasteboardHistory.ID) throws -> PasteboardHistory {
        try database.read { database in
            try #require(
                try PasteboardHistory.find(id).fetchOne(database)
            )
        }
    }

    func rawHistoryIDs() throws -> [String] {
        try database.read { database in
            try #sql(
                """
                SELECT "id"
                FROM "pasteboardHistories"
                ORDER BY "updateAt" DESC
                """,
                as: String.self
            )
            .fetchAll(database)
        }
    }

    func rawAssets(id: PasteboardHistory.ID) throws -> [PasteboardHistoryAsset] {
        try database.read { database in
            try PasteboardHistoryAsset
                .where { $0.pasteboardHistoryID.eq(id) }
                .order(by: \.index)
                .fetchAll(database)
        }
    }

    func rawThumbnail(id: PasteboardHistory.ID) throws -> PasteboardHistoryThumbnailAsset? {
        try database.read { database in
            try PasteboardHistoryThumbnailAsset
                .where { $0.pasteboardHistoryID.eq(id) }
                .fetchOne(database)
        }
    }

}

private extension PasteboardContent {
    init?(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        guard let content = PasteboardContent(assets: [PasteboardContent.Asset(type: .string, data: data)]) else {
            return nil
        }
        self = content
    }
}

private extension HistoryLockState {
    var keyID: UUID? {
        if case let .unlocked(keyID, _) = self {
            return keyID
        }
        return nil
    }
}
