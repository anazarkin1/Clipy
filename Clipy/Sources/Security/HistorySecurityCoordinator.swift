//
//  HistorySecurityCoordinator.swift
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
import Security
import SQLiteData

enum HistorySecurityCoordinatorError: Error, Equatable {
    case invalidState(HistoryLockState)
    case insufficientFreeSpace
    case missingTransitionMetadata
    case randomGenerationFailed(OSStatus)
    case injectedFailure(HistorySecurityTransitionStep)
}

enum HistorySecurityTransitionStep: Equatable {
    case enablePreflightComplete
    case enablingModePersisted
    case enableKeyCreated
    case enableHistoryDeleted
    case enableStorageCleaned
    case encryptedModeCommitted
    case disablingModePersisted
    case disableHistoryDeleted
    case disableStorageCleaned
    case disableKeyDeleted
    case plaintextModeCommitted
    case inaccessibleHistoryCleared
}

struct HistorySecurityCoordinator {
    @Dependency(\.defaultDatabase)
    private var database

    private let keyStore: EncryptionKeyStore
    private let hasSufficientFreeSpace: () throws -> Bool
    private let failureHook: (HistorySecurityTransitionStep) throws -> Void

    init(
        keyStore: EncryptionKeyStore = .live,
        hasSufficientFreeSpace: @escaping () throws -> Bool = { true },
        failureHook: @escaping (HistorySecurityTransitionStep) throws -> Void = { _ in }
    ) {
        self.keyStore = keyStore
        self.hasSufficientFreeSpace = hasSufficientFreeSpace
        self.failureHook = failureHook
    }

    func enableEncryption() throws -> HistoryLockState {
        guard try hasSufficientFreeSpace() else {
            throw HistorySecurityCoordinatorError.insufficientFreeSpace
        }
        try checkpoint(.enablePreflightComplete)

        let metadata = try currentMetadata()
        guard HistorySecurityMode(rawValue: metadata.mode) == .plaintext else {
            throw HistorySecurityCoordinatorError.invalidState(HistorySecurityBootstrap.startupState)
        }

        let keyID = UUID()
        let keyData = try randomKeyData()
        let keyCheck = HistoryKeyCheck.make(
            rootKey: keyData,
            keyID: keyID,
            databaseID: try metadata.databaseUUID()
        )

        try persistTransitionMetadata(mode: .enablingCleanup, keyID: keyID, keyCheck: keyCheck)
        HistorySecurityBootstrap.startupState = .transitioning(.enablingCleanup)
        try checkpoint(.enablingModePersisted)

        try keyStore.addKey(keyID, keyData)
        try checkpoint(.enableKeyCreated)

        try deleteHistoryStorage()
        try checkpoint(.enableHistoryDeleted)

        try cleanupStorage()
        try checkpoint(.enableStorageCleaned)

        try persistMode(.encrypted)
        let state = HistoryLockState.locked(keyID: keyID)
        HistorySecurityBootstrap.startupState = state
        try checkpoint(.encryptedModeCommitted)
        return state
    }

    func disableEncryption() throws -> HistoryLockState {
        let metadata = try currentMetadata()
        let mode = HistorySecurityMode(rawValue: metadata.mode)
        guard mode == .encrypted || mode == .enablingCleanup || mode == .disablingCleanup else {
            throw HistorySecurityCoordinatorError.invalidState(HistorySecurityBootstrap.startupState)
        }
        guard let keyID = metadata.keyUUID() else {
            throw HistorySecurityCoordinatorError.missingTransitionMetadata
        }

        try persistMode(.disablingCleanup)
        HistorySecurityBootstrap.startupState = .transitioning(.disablingCleanup)
        try checkpoint(.disablingModePersisted)

        try deleteHistoryStorage()
        try checkpoint(.disableHistoryDeleted)

        try cleanupStorage()
        try checkpoint(.disableStorageCleaned)

        try keyStore.deleteKey(keyID)
        try checkpoint(.disableKeyDeleted)

        try persistPlaintextMetadata()
        let state = HistoryLockState.plaintext
        HistorySecurityBootstrap.startupState = state
        try checkpoint(.plaintextModeCommitted)
        return state
    }

    func clearInaccessibleHistory() throws -> HistoryLockState {
        try deleteHistoryStorage()
        try cleanupStorage()
        try persistPlaintextMetadata()
        let state = HistoryLockState.plaintext
        HistorySecurityBootstrap.startupState = state
        try checkpoint(.inaccessibleHistoryCleared)
        return state
    }

    func recoverInterruptedTransition() throws -> HistoryLockState {
        let metadata = try currentMetadata()
        guard let mode = HistorySecurityMode(rawValue: metadata.mode) else {
            throw HistorySecurityCoordinatorError.missingTransitionMetadata
        }

        switch mode {
        case .plaintext:
            let state = HistoryLockState.plaintext
            HistorySecurityBootstrap.startupState = state
            return state
        case .encrypted:
            let state = HistorySecurityBootstrap(keyStore: keyStore).bootstrap()
            HistorySecurityBootstrap.startupState = state
            return state
        case .enablingCleanup:
            guard let keyID = metadata.keyUUID() else {
                try deleteHistoryStorage()
                try cleanupStorage()
                try persistPlaintextMetadata()
                let state = HistoryLockState.plaintext
                HistorySecurityBootstrap.startupState = state
                return state
            }
            try deleteHistoryStorage()
            try cleanupStorage()
            try persistMode(.encrypted)
            let state = HistoryLockState.locked(keyID: keyID)
            HistorySecurityBootstrap.startupState = state
            return state
        case .disablingCleanup:
            let keyID = metadata.keyUUID()
            try deleteHistoryStorage()
            try cleanupStorage()
            if let keyID {
                try keyStore.deleteKey(keyID)
            }
            try persistPlaintextMetadata()
            let state = HistoryLockState.plaintext
            HistorySecurityBootstrap.startupState = state
            return state
        }
    }

    private func checkpoint(_ step: HistorySecurityTransitionStep) throws {
        do {
            try failureHook(step)
        } catch let error as HistorySecurityCoordinatorError {
            throw error
        } catch {
            throw HistorySecurityCoordinatorError.injectedFailure(step)
        }
    }

    private func currentMetadata() throws -> HistorySecurityMetadata {
        try database.read { database in
            let rows = try #sql(
                """
                SELECT
                  "id",
                  "mode",
                  "formatVersion",
                  "databaseID",
                  "keyID",
                  "keyCheck",
                  "cleanupGeneration"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: HistorySecurityMetadata.self
            )
            .fetchAll(database)
            guard let metadata = rows.first else {
                throw HistorySecurityCoordinatorError.missingTransitionMetadata
            }
            return metadata
        }
    }

    private func persistTransitionMetadata(mode: HistorySecurityMode, keyID: UUID, keyCheck: Data) throws {
        try database.write { database in
            let generation = try cleanupGeneration(database: database) + 1
            try #sql(
                """
                UPDATE "historySecurityMetadata"
                SET
                  "mode" = \(bind: mode.rawValue),
                  "keyID" = \(bind: keyID.uuidString),
                  "keyCheck" = \(bind: keyCheck),
                  "cleanupGeneration" = \(bind: generation)
                WHERE "id" = 1
                """
            )
            .execute(database)
        }
    }

    private func persistMode(_ mode: HistorySecurityMode) throws {
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

    private func persistPlaintextMetadata() throws {
        try database.write { database in
            let generation = try cleanupGeneration(database: database) + 1
            try #sql(
                """
                UPDATE "historySecurityMetadata"
                SET
                  "mode" = 'plaintext',
                  "databaseID" = \(bind: UUID().uuidString),
                  "keyID" = NULL,
                  "keyCheck" = NULL,
                  "cleanupGeneration" = \(bind: generation)
                WHERE "id" = 1
                """
            )
            .execute(database)
        }
    }

    private func deleteHistoryStorage() throws {
        try database.write { database in
            try #sql(
                """
                DELETE FROM "pasteboardHistoryThumbnailAssets"
                """
            )
            .execute(database)
            try #sql(
                """
                DELETE FROM "pasteboardHistoryAssets"
                """
            )
            .execute(database)
            try #sql(
                """
                DELETE FROM "pasteboardHistories"
                """
            )
            .execute(database)
        }
    }

    private func cleanupStorage() throws {
        try DatabaseMigration().deleteLegacyHistoryStorage()
        try database.writeWithoutTransaction { database in
            try #sql(
                """
                PRAGMA wal_checkpoint(TRUNCATE)
                """
            )
            .execute(database)
        }
        try database.writeWithoutTransaction { database in
            try #sql(
                """
                VACUUM
                """
            )
            .execute(database)
        }
    }

    private func cleanupGeneration(database: Database) throws -> Int {
        try #sql(
            """
            SELECT "cleanupGeneration"
            FROM "historySecurityMetadata"
            WHERE "id" = 1
            """,
            as: Int.self
        )
        .fetchOne(database) ?? 0
    }

    private func randomKeyData() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw HistorySecurityCoordinatorError.randomGenerationFailed(status)
        }
        return data
    }
}

private extension HistorySecurityMetadata {
    func databaseUUID() throws -> UUID {
        guard let uuid = UUID(uuidString: databaseID) else {
            throw HistorySecurityCoordinatorError.missingTransitionMetadata
        }
        return uuid
    }

    func keyUUID() -> UUID? {
        keyID.flatMap(UUID.init(uuidString:))
    }
}
