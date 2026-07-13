//
//  LockManager.swift
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

final class LockManager {
    static let stateDidChangeNotification = Notification.Name("com.clipy.history.lock-state-did-change")
    static let screenSaverDidStartNotification = Notification.Name("com.apple.screensaver.didstart")
    static let mandatoryWorkspaceLockNotifications: [Notification.Name] = [
        NSWorkspace.screensDidSleepNotification,
        NSWorkspace.sessionDidResignActiveNotification,
        NSWorkspace.willSleepNotification
    ]
    static let mandatoryApplicationLockNotifications: [Notification.Name] = [
        NSApplication.didResignActiveNotification
    ]

    private static let stateLock = NSLock()
    private static var _generation = 0

    private var lastActivity: TimeInterval

    init(now: TimeInterval = 0) {
        self.lastActivity = now
    }

    static var generation: Int {
        stateLock.withLock { _generation }
    }

    @discardableResult
    func lockNow() -> HistoryLockState {
        Self.stateLock.lock()
        let oldState = HistorySecurityBootstrap.startupState
        let newState: HistoryLockState
        if case let .unlocked(keyID, _) = oldState {
            newState = .locked(keyID: keyID)
        } else {
            newState = oldState
        }
        if newState != oldState {
            HistorySecurityBootstrap.startupState = newState
            Self._generation += 1
        }
        let didChange = newState != oldState
        Self.stateLock.unlock()
        if didChange {
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: newState)
        }
        return newState
    }

    @discardableResult
    func unlock(keyStore: EncryptionKeyStore = .live) -> HistoryLockState {
        Self.stateLock.lock()
        let oldState = HistorySecurityBootstrap.startupState
        Self.stateLock.unlock()

        let newState = HistorySecurityBootstrap(keyStore: keyStore).unlock(oldState)

        Self.stateLock.lock()
        if newState != oldState {
            HistorySecurityBootstrap.startupState = newState
            Self._generation += 1
        }
        let didChange = newState != oldState
        Self.stateLock.unlock()
        if didChange {
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: newState)
        }
        return newState
    }

    @discardableResult
    func unlockIfLocked(keyStore: EncryptionKeyStore = .live) -> HistoryLockState {
        Self.stateLock.lock()
        let state = HistorySecurityBootstrap.startupState
        Self.stateLock.unlock()

        guard case .locked = state else { return state }
        return unlock(keyStore: keyStore)
    }

    func recordUserActivity(at now: TimeInterval) {
        lastActivity = now
    }

    @discardableResult
    func lockIfIdle(now: TimeInterval, timeout: TimeInterval?) -> Bool {
        guard let timeout, timeout > 0, now - lastActivity >= timeout else { return false }
        lockNow()
        return true
    }
}
