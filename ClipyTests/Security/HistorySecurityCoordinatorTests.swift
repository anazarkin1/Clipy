//
//  HistorySecurityCoordinatorTests.swift
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
import RealmSwift
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite(
    .serialized,
    .dependencies {
        $0.realmConfiguration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        try $0.bootstrapDatabase()
    }
)
struct HistorySecurityCoordinatorTests {
    @Dependency(\.defaultDatabase)
    var database
    @Dependency(\.realmConfiguration)
    var realmConfiguration

    @Test
    func enableDeletesHistoryCreatesKeyAndLeavesSnippetsIntact() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestKeyStore()
        try seedPlaintextHistoryAndSnippet()
        let legacyArchiveURL = try seedLegacyHistoryArchive()

        let state = try coordinator(keyStore: keyStore).enableEncryption()

        guard case let .locked(keyID) = state else {
            Issue.record("Enable did not finish locked")
            return
        }
        #expect(try metadataMode() == .encrypted)
        #expect(try metadataKeyID() == keyID)
        #expect(keyStore.keys[keyID] != nil)
        #expect(try rawHistoryCount() == 0)
        #expect(try snippetCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: legacyArchiveURL.path()))
        #expect(try legacyClipCount() == 0)
    }

    @Test
    func disableDeletesEncryptedHistoryAndKeyWithoutTouchingSnippets() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestKeyStore()
        try seedSnippet()
        let lockedState = try coordinator(keyStore: keyStore).enableEncryption()
        let keyID = try #require(lockedState.lockedKeyID)
        let keyData = try #require(keyStore.keys[keyID])
        HistorySecurityBootstrap.startupState = .unlocked(keyID: keyID, keyData: keyData)
        let repository = PasteboardHistoryRepository()
        let content = try #require(PasteboardContent("encrypted before disable"))
        let encryptedID = try historyID(for: content)
        repository.save(id: PasteboardHistory.ID(rawValue: content.hash), content: content, updateAt: 1)
        #expect(repository.fetchHistory(id: encryptedID)?.title == "encrypted before disable")

        let state = try coordinator(keyStore: keyStore).disableEncryption()

        #expect(state == .plaintext)
        #expect(try metadataMode() == .plaintext)
        #expect(try metadataKeyID() == nil)
        #expect(keyStore.keys[keyID] == nil)
        #expect(try rawHistoryCount() == 0)
        #expect(try snippetCount() == 1)
    }

    @Test
    func clearInaccessibleHistoryDoesNotManufactureMissingKey() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let missingKeyID = UUID()
        try seedPlaintextHistoryAndSnippet()
        try setEncryptedMetadataWithMissingKey(keyID: missingKeyID)
        HistorySecurityBootstrap.startupState = .keyMissing(keyID: missingKeyID)
        let keyStore = TestKeyStore()

        let state = try coordinator(keyStore: keyStore).clearInaccessibleHistory()

        #expect(state == .plaintext)
        #expect(keyStore.keys.isEmpty)
        #expect(try rawHistoryCount() == 0)
        #expect(try snippetCount() == 1)
        #expect(try metadataMode() == .plaintext)
    }

    @Test
    func insufficientFreeSpacePreventsEnableBeforeMetadataCommit() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestKeyStore()
        try seedPlaintextHistoryAndSnippet()

        do {
            _ = try coordinator(keyStore: keyStore, hasSufficientFreeSpace: { false }).enableEncryption()
            Issue.record("Enable unexpectedly succeeded without free space")
        } catch HistorySecurityCoordinatorError.insufficientFreeSpace {
        }

        #expect(try metadataMode() == .plaintext)
        #expect(keyStore.keys.isEmpty)
        #expect(try rawHistoryCount() == 1)
        #expect(try snippetCount() == 1)
    }

    @Test
    func keyCreationFailureRollsBackEnableTransition() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        try seedPlaintextHistoryAndSnippet()
        let keyStore = EncryptionKeyStore(
            addKey: { _, _ in throw EncryptionKeyStoreError.unexpected(errSecMissingEntitlement) },
            loadKey: { _, _ in throw EncryptionKeyStoreError.notFound },
            deleteKey: { _ in },
            inventoryKeyIDs: { [] }
        )

        do {
            _ = try HistorySecurityCoordinator(keyStore: keyStore).enableEncryption()
            Issue.record("Enable unexpectedly completed")
        } catch EncryptionKeyStoreError.unexpected(errSecMissingEntitlement) {
        }

        #expect(try metadataMode() == .plaintext)
        #expect(try metadataKeyID() == nil)
        #expect(try rawHistoryCount() == 1)
        #expect(try snippetCount() == 1)
        #expect(HistorySecurityBootstrap.startupState == .plaintext)
    }

    @Test
    func transitionStateRejectsCaptureAndOCR() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        try setMetadataMode(.enablingCleanup)
        HistorySecurityBootstrap.startupState = .transitioning(.enablingCleanup)
        let repository = PasteboardHistoryRepository()
        let content = try #require(PasteboardContent("during transition"))
        let id = PasteboardHistory.ID(rawValue: content.hash)

        repository.save(id: id, content: content, updateAt: 1)
        repository.updateOCRText(id: id, ocrText: "transition ocr")

        #expect(try rawHistoryCount() == 0)
    }

    @Test
    func interruptedEnableRecoversByDeletingHistoryAndReachingLocked() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestKeyStore()
        try seedPlaintextHistoryAndSnippet()
        let firstCoordinator = coordinator(keyStore: keyStore, failureHook: { step in
            if step == .enableKeyCreated {
                throw HistorySecurityCoordinatorError.injectedFailure(step)
            }
        })

        do {
            _ = try firstCoordinator.enableEncryption()
            Issue.record("Enable unexpectedly completed")
        } catch HistorySecurityCoordinatorError.injectedFailure(.enableKeyCreated) {
        }

        #expect(try metadataMode() == .enablingCleanup)
        #expect(try rawHistoryCount() == 1)

        let recoveredState = try coordinator(keyStore: keyStore).recoverInterruptedTransition()

        #expect(recoveredState.lockedKeyID != nil)
        #expect(try metadataMode() == .encrypted)
        #expect(try rawHistoryCount() == 0)
        #expect(try snippetCount() == 1)
    }

    @Test
    func interruptedEnableWithMissingKeyRollsBackToPlaintext() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestKeyStore()
        let missingKeyID = UUID()
        try seedPlaintextHistoryAndSnippet()
        try setEnablingCleanupMetadataWithMissingKey(keyID: missingKeyID)
        HistorySecurityBootstrap.startupState = .transitioning(.enablingCleanup)

        let recoveredState = try coordinator(keyStore: keyStore).recoverInterruptedTransition()

        #expect(recoveredState == .plaintext)
        #expect(try metadataMode() == .plaintext)
        #expect(try metadataKeyID() == nil)
        #expect(try rawHistoryCount() == 1)
        #expect(try snippetCount() == 1)
    }

    @Test
    func interruptedDisableRecoversByDeletingKeyAndReturningPlaintext() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestKeyStore()
        let lockedState = try coordinator(keyStore: keyStore).enableEncryption()
        let keyID = try #require(lockedState.lockedKeyID)
        let firstCoordinator = coordinator(keyStore: keyStore, failureHook: { step in
            if step == .disableStorageCleaned {
                throw HistorySecurityCoordinatorError.injectedFailure(step)
            }
        })

        do {
            _ = try firstCoordinator.disableEncryption()
            Issue.record("Disable unexpectedly completed")
        } catch HistorySecurityCoordinatorError.injectedFailure(.disableStorageCleaned) {
        }

        #expect(try metadataMode() == .disablingCleanup)
        #expect(keyStore.keys[keyID] != nil)

        let recoveredState = try coordinator(keyStore: keyStore).recoverInterruptedTransition()

        #expect(recoveredState == .plaintext)
        #expect(try metadataMode() == .plaintext)
        #expect(keyStore.keys[keyID] == nil)
    }
}

private extension HistorySecurityCoordinatorTests {
    func coordinator(
        keyStore: TestKeyStore,
        hasSufficientFreeSpace: @escaping () throws -> Bool = { true },
        failureHook: @escaping (HistorySecurityTransitionStep) throws -> Void = { _ in }
    ) -> HistorySecurityCoordinator {
        HistorySecurityCoordinator(
            keyStore: keyStore.store,
            hasSufficientFreeSpace: hasSufficientFreeSpace,
            failureHook: failureHook
        )
    }

    func seedPlaintextHistoryAndSnippet() throws {
        try seedSnippet()
        let historyID = PasteboardHistory.ID(rawValue: "history")
        try database.write { database in
            try PasteboardHistory.insert {
                PasteboardHistory(
                    id: historyID,
                    title: "history marker",
                    ocrText: "ocr marker",
                    pasteboardTypes: [.string],
                    createdAt: 1,
                    updateAt: 1,
                    deviceID: nil
                )
            }
            .execute(database)
            try PasteboardHistoryAsset.insert {
                PasteboardHistoryAsset.Draft(
                    pasteboardHistoryID: historyID,
                    index: 0,
                    pasteboardType: .string,
                    data: Data("asset marker".utf8)
                )
            }
            .execute(database)
        }
    }

    func seedSnippet() throws {
        try database.write { database in
            let folderID = SnippetFolder.ID(rawValue: UUID())
            try SnippetFolder.insert {
                SnippetFolder(id: folderID, title: "Folder", index: 0, isEnabled: true)
            }
            .execute(database)
            try Snippet.insert {
                Snippet(
                    id: Snippet.ID(rawValue: UUID()),
                    folderID: folderID,
                    title: "Snippet",
                    content: "snippet marker",
                    index: 0,
                    isEnabled: true
                )
            }
            .execute(database)
        }
    }

    func seedLegacyHistoryArchive() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("legacy history marker".utf8).write(to: url)
        let clip = CPYClip()
        clip.dataPath = url.path()
        clip.title = "legacy"
        clip.dataHash = "legacy"
        clip.updateTime = 1
        let realm = try Realm(configuration: realmConfiguration)
        try realm.write {
            realm.add(clip)
        }
        return url
    }

    func legacyClipCount() throws -> Int {
        let realm = try Realm(configuration: realmConfiguration)
        return realm.objects(CPYClip.self).count
    }

    func setEncryptedMetadataWithMissingKey(keyID: UUID) throws {
        try setProtectedMetadata(mode: .encrypted, keyID: keyID)
    }

    func setEnablingCleanupMetadataWithMissingKey(keyID: UUID) throws {
        try setProtectedMetadata(mode: .enablingCleanup, keyID: keyID)
    }

    func setProtectedMetadata(mode: HistorySecurityMode, keyID: UUID) throws {
        let keyData = Data(repeating: 0x71, count: 32)
        let databaseID = UUID()
        let keyCheck = HistoryKeyCheck.make(rootKey: keyData, keyID: keyID, databaseID: databaseID)
        try database.write { database in
            try #sql(
                """
                UPDATE "historySecurityMetadata"
                SET
                  "mode" = \(bind: mode.rawValue),
                  "databaseID" = \(bind: databaseID.uuidString),
                  "keyID" = \(bind: keyID.uuidString),
                  "keyCheck" = \(bind: keyCheck)
                WHERE "id" = 1
                """
            )
            .execute(database)
        }
    }

    func setMetadataMode(_ mode: HistorySecurityMode) throws {
        try database.write { database in
            try #sql(
                """
                UPDATE "historySecurityMetadata"
                SET "mode" = \(bind: mode.rawValue)
                WHERE "id" = 1
                """
            )
            .execute(database)
        }
    }

    func historyID(for content: PasteboardContent) throws -> PasteboardHistory.ID {
        try database.read { database in
            let cryptoService = try #require(try CryptoService(database: database))
            return cryptoService.historyID(for: content)
        }
    }

    func metadataMode() throws -> HistorySecurityMode? {
        try database.read { database in
            let mode = try #sql(
                """
                SELECT "mode"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: String.self
            )
            .fetchOne(database)
            return mode.flatMap(HistorySecurityMode.init(rawValue:))
        }
    }

    func metadataKeyID() throws -> UUID? {
        try database.read { database in
            let keyID = try #sql(
                """
                SELECT "keyID"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: String?.self
            )
            .fetchOne(database)
            return keyID.flatMap { $0 }.flatMap(UUID.init(uuidString:))
        }
    }

    func rawHistoryCount() throws -> Int {
        try database.read { database in
            try #sql(
                """
                SELECT count(*)
                FROM "pasteboardHistories"
                """,
                as: Int.self
            )
            .fetchOne(database) ?? 0
        }
    }

    func snippetCount() throws -> Int {
        try database.read { database in
            try #sql(
                """
                SELECT count(*)
                FROM "snippets"
                """,
                as: Int.self
            )
            .fetchOne(database) ?? 0
        }
    }
}

private final class TestKeyStore {
    var keys = [UUID: Data]()

    var store: EncryptionKeyStore {
        EncryptionKeyStore(
            addKey: { [self] keyID, keyData in
                keys[keyID] = keyData
            },
            loadKey: { [self] keyID, _ in
                guard let key = keys[keyID] else { throw EncryptionKeyStoreError.notFound }
                return key
            },
            deleteKey: { [self] keyID in
                keys[keyID] = nil
            },
            inventoryKeyIDs: { [self] in
                Array(keys.keys)
            }
        )
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
    var lockedKeyID: UUID? {
        if case let .locked(keyID) = self {
            return keyID
        }
        return nil
    }
}
