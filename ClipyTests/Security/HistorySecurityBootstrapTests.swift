//
//  HistorySecurityBootstrapTests.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import Dependencies
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite
struct HistorySecurityBootstrapTests {
    @Test
    func plaintextMetadataWithoutKeysEntersPlaintext() throws {
        let database = try migratedDatabase()
        let state = bootstrap(database: database, keyStore: .test(inventory: []))

        #expect(state == .plaintext)
        #expect(state.allowsHistoryServices)
        #expect(state.allowsRealmHistoryImport)
    }

    @Test
    func plaintextMetadataWithOrphanKeyBlocksHistoryServices() throws {
        let database = try migratedDatabase()
        let orphanKeyID = UUID()
        let state = bootstrap(database: database, keyStore: .test(inventory: [orphanKeyID]))

        #expect(state == .blockedByOrphanKeys([orphanKeyID]))
        #expect(!state.allowsHistoryServices)
        #expect(!state.allowsRealmHistoryImport)
    }

    @Test
    func encryptedMetadataWithMatchingInventoryEntersLockedAndUnlockVerifiesKeyCheck() throws {
        let database = try migratedDatabase()
        let keyID = UUID()
        let databaseID = UUID()
        let key = Data(repeating: 0x33, count: 32)
        let keyCheck = HistoryKeyCheck.make(rootKey: key, keyID: keyID, databaseID: databaseID)
        try updateMetadata(database, mode: .encrypted, databaseID: databaseID, keyID: keyID, keyCheck: keyCheck)

        let keyStore = EncryptionKeyStore.test(inventory: [keyID], keys: [keyID: key])
        let state = bootstrap(database: database, keyStore: keyStore)
        let unlockedState = unlock(state, database: database, keyStore: keyStore)

        #expect(state == .locked(keyID: keyID))
        #expect(!state.allowsHistoryServices)
        #expect(unlockedState == .unlocked(keyID: keyID, keyData: key))
        #expect(unlockedState.allowsHistoryServices)
    }

    @Test
    func encryptedMetadataWithMissingKeyDoesNotEnterPlaintext() throws {
        let database = try migratedDatabase()
        let keyID = UUID()
        let databaseID = UUID()
        let key = Data(repeating: 0x44, count: 32)
        let keyCheck = HistoryKeyCheck.make(rootKey: key, keyID: keyID, databaseID: databaseID)
        try updateMetadata(database, mode: .encrypted, databaseID: databaseID, keyID: keyID, keyCheck: keyCheck)

        let state = bootstrap(database: database, keyStore: .test(inventory: []))

        #expect(state == .keyMissing(keyID: keyID))
        #expect(!state.allowsHistoryServices)
        #expect(!state.allowsRealmHistoryImport)
    }

    @Test
    func unavailableKeychainBlocksEncryptedHistory() throws {
        let database = try migratedDatabase()
        let keyID = UUID()
        let databaseID = UUID()
        let key = Data(repeating: 0x55, count: 32)
        let keyCheck = HistoryKeyCheck.make(rootKey: key, keyID: keyID, databaseID: databaseID)
        try updateMetadata(database, mode: .encrypted, databaseID: databaseID, keyID: keyID, keyCheck: keyCheck)

        let state = bootstrap(database: database, keyStore: .test(inventoryError: .unavailable))

        #expect(state == .keyUnavailable(keyID: keyID))
        #expect(!state.allowsHistoryServices)
    }

    @Test
    func malformedMetadataAndKeyChecksEnterCorrupt() throws {
        let malformedIDDatabase = try migratedDatabase()
        try setRawMetadata(malformedIDDatabase, mode: "plaintext", databaseID: "not-a-uuid", keyID: nil, keyCheck: nil)

        let malformedCheckDatabase = try migratedDatabase()
        try updateMetadata(
            malformedCheckDatabase,
            mode: .encrypted,
            databaseID: UUID(),
            keyID: UUID(),
            keyCheck: Data([0x00])
        )

        if case .corrupt = bootstrap(database: malformedIDDatabase, keyStore: .test(inventory: [])) {
        } else {
            Issue.record("Malformed database ID did not enter corrupt")
        }

        if case .corrupt = bootstrap(database: malformedCheckDatabase, keyStore: .test(inventory: [])) {
        } else {
            Issue.record("Malformed key check did not enter corrupt")
        }
    }
}

private extension HistorySecurityBootstrapTests {
    func migratedDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration()
        try migrator.migrate(database)
        return database
    }

    func bootstrap(database: DatabaseQueue, keyStore: EncryptionKeyStore) -> HistoryLockState {
        withDependencies {
            $0.defaultDatabase = database
        } operation: {
            HistorySecurityBootstrap(keyStore: keyStore).bootstrap()
        }
    }

    func unlock(_ state: HistoryLockState, database: DatabaseQueue, keyStore: EncryptionKeyStore) -> HistoryLockState {
        withDependencies {
            $0.defaultDatabase = database
        } operation: {
            HistorySecurityBootstrap(keyStore: keyStore).unlock(state)
        }
    }

    func updateMetadata(
        _ database: DatabaseQueue,
        mode: HistorySecurityMode,
        databaseID: UUID,
        keyID: UUID?,
        keyCheck: Data?
    ) throws {
        try setRawMetadata(
            database,
            mode: mode.rawValue,
            databaseID: databaseID.uuidString,
            keyID: keyID?.uuidString,
            keyCheck: keyCheck
        )
    }

    func setRawMetadata(
        _ database: DatabaseQueue,
        mode: String,
        databaseID: String,
        keyID: String?,
        keyCheck: Data?
    ) throws {
        try database.write { database in
            try #sql(
                """
                UPDATE "historySecurityMetadata"
                SET
                  "mode" = \(bind: mode),
                  "databaseID" = \(bind: databaseID),
                  "keyID" = \(bind: keyID),
                  "keyCheck" = \(bind: keyCheck)
                WHERE "id" = 1
                """
            )
            .execute(database)
        }
    }
}

private extension EncryptionKeyStore {
    static func test(
        inventory: [UUID] = [],
        inventoryError: EncryptionKeyStoreError? = nil,
        keys: [UUID: Data] = [:]
    ) -> EncryptionKeyStore {
        EncryptionKeyStore(
            addKey: { _, _ in },
            loadKey: { keyID, _ in
                guard let key = keys[keyID] else { throw EncryptionKeyStoreError.notFound }
                return key
            },
            deleteKey: { _ in },
            inventoryKeyIDs: {
                if let inventoryError { throw inventoryError }
                return inventory
            }
        )
    }
}
