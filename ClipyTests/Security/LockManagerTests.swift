//
//  LockManagerTests.swift
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
import Security
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
struct LockManagerTests {
    @Dependency(\.defaultDatabase)
    var database

    @Test
    func lockNowTurnsUnlockedIntoLockedAndBumpsGeneration() {
        let keyID = UUID()
        HistorySecurityBootstrap.startupState = .unlocked(keyID: keyID, keyData: Data(repeating: 0x01, count: 32))
        let generation = LockManager.generation
        defer { HistorySecurityBootstrap.startupState = .plaintext }

        let state = LockManager().lockNow()

        #expect(state == .locked(keyID: keyID))
        #expect(LockManager.generation == generation + 1)
    }

    @Test
    func idleTimeoutLocksAtBoundaryAndActivityResetsDeadline() {
        let keyID = UUID()
        HistorySecurityBootstrap.startupState = .unlocked(keyID: keyID, keyData: Data(repeating: 0x02, count: 32))
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let lockManager = LockManager(now: 0)
        lockManager.recordUserActivity(at: 5)

        #expect(!lockManager.lockIfIdle(now: 14, timeout: 10))
        #expect(HistorySecurityBootstrap.startupState == .unlocked(keyID: keyID, keyData: Data(repeating: 0x02, count: 32)))
        #expect(lockManager.lockIfIdle(now: 15, timeout: 10))
        #expect(HistorySecurityBootstrap.startupState == .locked(keyID: keyID))
    }

    @Test
    func mandatoryLifecycleNotificationsAreRegisteredForLocking() {
        #expect(LockManager.mandatoryWorkspaceLockNotifications.contains(NSWorkspace.screensDidSleepNotification))
        #expect(LockManager.mandatoryWorkspaceLockNotifications.contains(NSWorkspace.sessionDidResignActiveNotification))
        #expect(LockManager.mandatoryWorkspaceLockNotifications.contains(NSWorkspace.willSleepNotification))
        #expect(LockManager.mandatoryApplicationLockNotifications.contains(NSApplication.didResignActiveNotification))
        #expect(LockManager.screenSaverDidStartNotification.rawValue == "com.apple.screensaver.didstart")
    }

    @Test
    func lockedCaptureStoresNothingAndResumesAfterUnlock() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestLockKeyStore()
        let coordinator = HistorySecurityCoordinator(keyStore: keyStore.store)
        let lockedState = try coordinator.enableEncryption()
        let keyID = try #require(lockedState.lockedKeyID)
        try #require(keyStore.keys[keyID] != nil)
        let repository = PasteboardHistoryRepository()
        let clipService = withDependencies {
            $0.pasteboardHistoryRepository = repository
            $0.textRecognizer = NoopTextRecognizer()
        } operation: {
            ClipService()
        }

        clipService.create(with: NSImage.create(with: .blue, size: NSSize(width: 20, height: 20)))
        #expect(try rawHistoryCount() == 0)

        #expect(LockManager().unlock(keyStore: keyStore.store).unlockedKeyID == keyID)
        clipService.create(with: NSImage.create(with: .red, size: NSSize(width: 20, height: 20)))
        #expect(try rawHistoryCount() == 1)
    }

    @Test
    func authenticationCancellationLeavesHistoryLockedAndCaptureBlocked() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestLockKeyStore()
        let coordinator = HistorySecurityCoordinator(keyStore: keyStore.store)
        let lockedState = try coordinator.enableEncryption()
        let repository = PasteboardHistoryRepository()
        let clipService = withDependencies {
            $0.pasteboardHistoryRepository = repository
            $0.textRecognizer = NoopTextRecognizer()
        } operation: {
            ClipService()
        }

        let stateAfterCancellation = LockManager().unlock(keyStore: keyStore.cancelingStore)

        #expect(stateAfterCancellation == lockedState)
        #expect(HistorySecurityBootstrap.startupState == lockedState)
        clipService.create(with: NSImage.create(with: .blue, size: NSSize(width: 20, height: 20)))
        #expect(try rawHistoryCount() == 0)
    }

    @Test
    func unlockIfLockedUnlocksEncryptedHistory() throws {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        let keyStore = TestLockKeyStore()
        let coordinator = HistorySecurityCoordinator(keyStore: keyStore.store)
        let lockedState = try coordinator.enableEncryption()
        let keyID = try #require(lockedState.lockedKeyID)

        let state = LockManager().unlockIfLocked(keyStore: keyStore.store)

        #expect(state.unlockedKeyID == keyID)
        #expect(HistorySecurityBootstrap.startupState.unlockedKeyID == keyID)
    }

    @Test
    func unlockIfLockedSkipsNonLockedStates() {
        defer { HistorySecurityBootstrap.startupState = .plaintext }
        var didLoadKey = false
        HistorySecurityBootstrap.startupState = .plaintext
        let keyStore = EncryptionKeyStore(
            addKey: { _, _ in },
            loadKey: { _, _ in
                didLoadKey = true
                throw EncryptionKeyStoreError.unexpected(errSecInternalError)
            },
            deleteKey: { _ in },
            inventoryKeyIDs: { [] }
        )

        let state = LockManager().unlockIfLocked(keyStore: keyStore)

        #expect(state == .plaintext)
        #expect(HistorySecurityBootstrap.startupState == .plaintext)
        #expect(!didLoadKey)
    }
}

private extension LockManagerTests {
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

private final class TestLockKeyStore {
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

    var cancelingStore: EncryptionKeyStore {
        EncryptionKeyStore(
            addKey: store.addKey,
            loadKey: { _, _ in
                throw EncryptionKeyStoreError.canceled
            },
            deleteKey: store.deleteKey,
            inventoryKeyIDs: store.inventoryKeyIDs
        )
    }
}

private struct NoopTextRecognizer: TextRecognizerProtocol {
    func recognizeTextIfNeeded(id: PasteboardHistory.ID) {}
}

private extension HistoryLockState {
    var lockedKeyID: UUID? {
        if case let .locked(keyID) = self {
            return keyID
        }
        return nil
    }

    var unlockedKeyID: UUID? {
        if case let .unlocked(keyID, _) = self {
            return keyID
        }
        return nil
    }
}
