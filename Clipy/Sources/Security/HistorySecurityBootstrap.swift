//
//  HistorySecurityBootstrap.swift
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

struct HistorySecurityBootstrap {
    static var startupState: HistoryLockState = .corrupt("History security bootstrap has not run")

    @Dependency(\.defaultDatabase)
    private var database

    private let keyStore: EncryptionKeyStore

    init(keyStore: EncryptionKeyStore = .live) {
        self.keyStore = keyStore
    }

    func bootstrap() -> HistoryLockState {
        do {
            guard let metadata = try metadata() else {
                return .corrupt("Missing history security metadata")
            }
            guard metadata.formatVersion == 1 else {
                return .corrupt("Unsupported history security metadata format")
            }
            guard let mode = HistorySecurityMode(rawValue: metadata.mode) else {
                return .corrupt("Unknown history security mode")
            }
            guard let databaseID = UUID(uuidString: metadata.databaseID) else {
                return .corrupt("Malformed history database ID")
            }

            switch mode {
            case .plaintext:
                return try plaintextState()
            case .encrypted:
                return try protectedState(metadata: metadata, databaseID: databaseID)
            case .enablingCleanup, .disablingCleanup:
                return .transitioning(mode)
            }
        } catch let error as EncryptionKeyStoreError {
            switch error {
            case .unavailable, .interactionNotAllowed:
                return .keyUnavailable(keyID: nil)
            case .notFound, .canceled, .authenticationFailed, .unexpected:
                return .corrupt("Unable to reconcile history encryption keys")
            }
        } catch {
            return .corrupt("Unable to read history security metadata")
        }
    }

    func unlock(_ state: HistoryLockState) -> HistoryLockState {
        guard case let .locked(keyID) = state else { return state }
        do {
            guard let metadata = try metadata(),
                  let databaseID = UUID(uuidString: metadata.databaseID),
                  let keyCheck = metadata.keyCheck,
                  HistoryKeyCheck.isWellFormed(keyCheck) else {
                return .corrupt("Malformed history key check")
            }

            let keyData = try keyStore.loadKey(keyID, true)
            guard HistoryKeyCheck.verify(keyCheck, rootKey: keyData, keyID: keyID, databaseID: databaseID) else {
                return .corrupt("History key check verification failed")
            }
            return .unlocked(keyID: keyID, keyData: keyData)
        } catch let error as EncryptionKeyStoreError {
            switch error {
            case .notFound:
                return .keyMissing(keyID: keyID)
            case .unavailable, .interactionNotAllowed:
                return .keyUnavailable(keyID: keyID)
            case .canceled, .authenticationFailed, .unexpected:
                return .corrupt("Unable to unlock history encryption key")
            }
        } catch {
            return .corrupt("Unable to unlock history encryption key")
        }
    }

    private func metadata() throws -> HistorySecurityMetadata? {
        let metadataRows: [HistorySecurityMetadata] = try database.read { database in
            let ids = try #sql(
                """
                SELECT "id"
                FROM "historySecurityMetadata"
                """,
                as: Int.self
            )
            .fetchAll(database)
            guard ids == [1] else { return [] }

            let mode = try #sql(
                """
                SELECT "mode"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: String.self
            )
            .fetchOne(database)

            let formatVersion = try #sql(
                """
                SELECT "formatVersion"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: Int.self
            )
            .fetchOne(database)

            let databaseID = try #sql(
                """
                SELECT "databaseID"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: String.self
            )
            .fetchOne(database)

            let keyID = try #sql(
                """
                SELECT "keyID"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: String?.self
            )
            .fetchOne(database)

            let keyCheck = try #sql(
                """
                SELECT "keyCheck"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: Data?.self
            )
            .fetchOne(database)

            let cleanupGeneration = try #sql(
                """
                SELECT "cleanupGeneration"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: Int.self
            )
            .fetchOne(database)

            guard let mode, let formatVersion, let databaseID, let cleanupGeneration else {
                return []
            }
            let resolvedKeyID = keyID.flatMap { $0 }
            let resolvedKeyCheck = keyCheck.flatMap { $0 }
            return [
                HistorySecurityMetadata(
                    id: 1,
                    mode: mode,
                    formatVersion: formatVersion,
                    databaseID: databaseID,
                    keyID: resolvedKeyID,
                    keyCheck: resolvedKeyCheck,
                    cleanupGeneration: cleanupGeneration
                )
            ]
        }
        return metadataRows.first
    }

    private func plaintextState() throws -> HistoryLockState {
        let keyIDs = try keyStore.inventoryKeyIDs().sorted { $0.uuidString < $1.uuidString }
        return keyIDs.isEmpty ? .plaintext : .blockedByOrphanKeys(keyIDs)
    }

    private func protectedState(metadata: HistorySecurityMetadata, databaseID: UUID) throws -> HistoryLockState {
        guard let keyIDString = metadata.keyID,
              let keyID = UUID(uuidString: keyIDString) else {
            return .corrupt("Protected history mode is missing a valid key ID")
        }
        guard let keyCheck = metadata.keyCheck,
              HistoryKeyCheck.isWellFormed(keyCheck) else {
            return .corrupt("Protected history mode has a malformed key check")
        }

        do {
            let keyIDs = try keyStore.inventoryKeyIDs()
            return keyIDs.contains(keyID) ? .locked(keyID: keyID) : .keyMissing(keyID: keyID)
        } catch let error as EncryptionKeyStoreError {
            switch error {
            case .unavailable, .interactionNotAllowed:
                return .keyUnavailable(keyID: keyID)
            case .notFound, .canceled, .authenticationFailed, .unexpected:
                return .corrupt("Unable to inventory history encryption keys")
            }
        }
    }
}
