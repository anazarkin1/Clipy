//
//  SecuritySettingsViewModel.swift
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
import Foundation
import LocalAuthentication

@MainActor
final class SecuritySettingsViewModel: ObservableObject {
    enum PendingConfirmation: Equatable {
        case enable
        case disable
    }

    struct Actions {
        var enableEncryption: () throws -> HistoryLockState
        var disableEncryption: () throws -> HistoryLockState
        var clearInaccessibleHistory: () throws -> HistoryLockState
        var lockNow: () -> HistoryLockState
        var unlock: () async -> HistoryLockState

        static let live = Actions(
            enableEncryption: { try HistorySecurityCoordinator().enableEncryption() },
            disableEncryption: { try HistorySecurityCoordinator().disableEncryption() },
            clearInaccessibleHistory: { try HistorySecurityCoordinator().clearInaccessibleHistory() },
            lockNow: { LockManager().lockNow() },
            unlock: { await LockManager().authenticatedUnlock() }
        )
    }

    @Published private(set) var state: HistoryLockState
    @Published private(set) var isTransitioning = false
    @Published private(set) var statusMessage: String
    @Published var pendingConfirmation: PendingConfirmation?

    let authenticationDescription: String
    private let actions: Actions

    init(
        state: HistoryLockState = HistorySecurityBootstrap.startupState,
        actions: Actions = .live,
        canEvaluateOwnerAuthentication: () -> Bool = SecuritySettingsViewModel.canEvaluateOwnerAuthentication
    ) {
        self.state = state
        self.actions = actions
        self.statusMessage = SecuritySettingsViewModel.statusText(for: state)
        self.authenticationDescription = canEvaluateOwnerAuthentication()
            ? String(localized: "Unlock uses Touch ID, Apple Watch, or your Mac password when available.")
            : String(localized: "Unlock requires macOS user authentication when available.")
    }

    var enableConfirmationText: String {
        String(localized: "Enable encrypted history? This permanently clears existing clipboard history. Snippets are unaffected.")
    }

    var disableConfirmationText: String {
        String(localized: "Disable encrypted history? This permanently clears encrypted clipboard history. Snippets are unaffected.")
    }

    var canEnable: Bool {
        state == .plaintext && !isTransitioning
    }

    var canDisable: Bool {
        switch state {
        case .locked, .unlocked, .keyUnavailable, .keyMissing:
            return !isTransitioning
        case .plaintext, .blockedByOrphanKeys, .transitioning, .corrupt:
            return false
        }
    }

    var canLockNow: Bool {
        if case .unlocked = state, !isTransitioning {
            return true
        }
        return false
    }

    var canUnlock: Bool {
        if case .locked = state, !isTransitioning {
            return true
        }
        return false
    }

    var canClearInaccessibleHistory: Bool {
        if case .keyMissing = state, !isTransitioning {
            return true
        }
        return false
    }

    var recoveryHelpText: String {
        switch state {
        case .keyMissing:
            return String(localized: "The expected key is missing. You can clear inaccessible encrypted history and return to empty plaintext history.")
        case .keyUnavailable:
            return String(localized: "The key is temporarily unavailable. Retry unlock or check macOS authentication; destructive recovery is not the default action.")
        case .corrupt:
            return String(localized: "History security metadata is inconsistent. Review logs before attempting recovery.")
        default:
            return ""
        }
    }

    func requestEnable() {
        guard canEnable else { return }
        pendingConfirmation = .enable
    }

    func requestDisable() {
        guard canDisable else { return }
        pendingConfirmation = .disable
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
        statusMessage = SecuritySettingsViewModel.statusText(for: state)
    }

    func confirmPendingAction() {
        guard let pendingConfirmation, !isTransitioning else { return }
        self.pendingConfirmation = nil
        switch pendingConfirmation {
        case .enable:
            perform(actions.enableEncryption)
        case .disable:
            perform(actions.disableEncryption)
        }
    }

    func lockNow() {
        guard canLockNow else { return }
        updateState(actions.lockNow())
    }

    func unlock() {
        guard canUnlock else { return }
        Task { updateState(await actions.unlock()) }
    }

    func clearInaccessibleHistory() {
        guard canClearInaccessibleHistory else { return }
        perform(actions.clearInaccessibleHistory)
    }

    func refreshState(_ state: HistoryLockState = HistorySecurityBootstrap.startupState) {
        updateState(state)
    }

    private func perform(_ operation: () throws -> HistoryLockState) {
        guard !isTransitioning else { return }
        isTransitioning = true
        statusMessage = String(localized: "Updating history security…")
        do {
            updateState(try operation())
        } catch {
            statusMessage = String(localized: "History security update failed: \(String(describing: error)). Retry is safe.")
        }
        isTransitioning = false
    }

    private func updateState(_ state: HistoryLockState) {
        self.state = state
        statusMessage = SecuritySettingsViewModel.statusText(for: state)
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested)
    }

    nonisolated private static func canEvaluateOwnerAuthentication() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    private static func statusText(for state: HistoryLockState) -> String {
        switch state {
        case .plaintext:
            return String(localized: "History encryption is off.")
        case .blockedByOrphanKeys:
            return String(localized: "History encryption is blocked by orphaned keys.")
        case .locked:
            return String(localized: "Encrypted history is locked.")
        case .unlocked:
            return String(localized: "Encrypted history is unlocked for this session.")
        case .keyMissing:
            return String(localized: "Encrypted history key is missing.")
        case .keyUnavailable:
            return String(localized: "Encrypted history key is temporarily unavailable.")
        case .transitioning:
            return String(localized: "History security maintenance is in progress.")
        case .corrupt:
            return String(localized: "History security needs attention.")
        }
    }
}
