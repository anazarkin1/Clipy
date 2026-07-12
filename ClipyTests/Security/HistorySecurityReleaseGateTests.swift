//
//  HistorySecurityReleaseGateTests.swift
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
import DependenciesTestSupport
import Foundation
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
struct HistorySecurityReleaseGateTests {
    @Dependency(\.defaultDatabase)
    var database

    @Test
    func cleanInstallBootstrapsPlaintextMetadata() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }

        let state = HistorySecurityBootstrap(keyStore: TestReleaseGateKeyStore().store).bootstrap()
        HistorySecurityBootstrap.startupState = state

        #expect(state == .plaintext)
        #expect(try metadataModes() == ["plaintext"])
        #expect(try rawHistoryCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func oneHundredEnableDisableCyclesLeaveConsistentEmptyMetadataAndNoOrphanKeys() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestReleaseGateKeyStore()
        let coordinator = HistorySecurityCoordinator(keyStore: keyStore.store)

        for _ in 0..<100 {
            let lockedState = try coordinator.enableEncryption()
            guard case let .locked(keyID) = lockedState else {
                Issue.record("Enable did not return locked state")
                return
            }
            #expect(try metadataModes() == ["encrypted"])
            #expect(try rawHistoryCount() == 0)
            #expect(keyStore.keys[keyID] != nil)

            let plaintextState = try coordinator.disableEncryption()
            #expect(plaintextState == .plaintext)
            #expect(try metadataModes() == ["plaintext"])
            #expect(try rawHistoryCount() == 0)
            #expect(keyStore.keys.isEmpty)
        }
    }
}

private extension HistorySecurityReleaseGateTests {
    func metadataModes() throws -> [String] {
        try database.read { database in
            try #sql(
                """
                SELECT "mode"
                FROM "historySecurityMetadata"
                ORDER BY "id"
                """,
                as: String.self
            )
            .fetchAll(database)
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
}

private final class TestReleaseGateKeyStore {
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
