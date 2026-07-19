//
//  SecuritySettingsViewModelTests.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import Foundation
import Testing
@testable import Clipy

@MainActor
@Suite(.serialized)
struct SecuritySettingsViewModelTests {
    @Test
    func cancellingEnableOrDisablePerformsNoSecurityAction() {
        let recorder = ActionRecorder()
        let keyID = UUID()
        let viewModel = SecuritySettingsViewModel(
            state: .plaintext,
            actions: actions(recording: recorder, disabledState: .locked(keyID: keyID))
        )

        viewModel.requestEnable()
        viewModel.cancelConfirmation()
        #expect(recorder.calls.isEmpty)
        #expect(viewModel.state == .plaintext)

        viewModel.refreshState(.locked(keyID: keyID))
        viewModel.requestDisable()
        viewModel.cancelConfirmation()
        #expect(recorder.calls.isEmpty)
        #expect(viewModel.state == .locked(keyID: keyID))
    }

    @Test
    func confirmationTextNamesPermanentHistoryDeletionAndSnippets() {
        let viewModel = SecuritySettingsViewModel(state: .plaintext)

        #expect(viewModel.enableConfirmationText.localizedCaseInsensitiveContains("permanently clears"))
        #expect(viewModel.enableConfirmationText.localizedCaseInsensitiveContains("clipboard history"))
        #expect(viewModel.enableConfirmationText.localizedCaseInsensitiveContains("Snippets are unaffected"))
        #expect(viewModel.disableConfirmationText.localizedCaseInsensitiveContains("encrypted clipboard history"))
        #expect(viewModel.disableConfirmationText.localizedCaseInsensitiveContains("Snippets are unaffected"))
    }

    @Test
    func confirmedActionsCallCoordinatorClosuresRatherThanDefaults() {
        let recorder = ActionRecorder()
        let keyID = UUID()
        let viewModel = SecuritySettingsViewModel(
            state: .plaintext,
            actions: actions(recording: recorder, enabledState: .locked(keyID: keyID), disabledState: .plaintext)
        )

        viewModel.requestEnable()
        viewModel.confirmPendingAction()

        #expect(recorder.calls == ["enable"])
        #expect(viewModel.state == .locked(keyID: keyID))

        viewModel.requestDisable()
        viewModel.confirmPendingAction()

        #expect(recorder.calls == ["enable", "disable"])
        #expect(viewModel.state == .plaintext)
    }

    @Test
    func transitionFailureIsRetryableAndPreventsDuplicateActionsWhileBusy() {
        var enableCalls = 0
        let actions = SecuritySettingsViewModel.Actions(
            enableEncryption: {
                enableCalls += 1
                throw HistorySecurityCoordinatorError.insufficientFreeSpace
            },
            disableEncryption: { .plaintext },
            clearInaccessibleHistory: { .plaintext },
            lockNow: { .plaintext },
            unlock: { .plaintext }
        )
        let viewModel = SecuritySettingsViewModel(state: .plaintext, actions: actions)

        viewModel.requestEnable()
        viewModel.confirmPendingAction()
        viewModel.requestEnable()
        viewModel.confirmPendingAction()

        #expect(enableCalls == 2)
        #expect(!viewModel.isTransitioning)
        #expect(viewModel.canEnable)
        #expect(viewModel.statusMessage.localizedCaseInsensitiveContains("failed"))
    }

    @Test
    func recoveryActionsSeparateMissingAndUnavailableKeys() {
        let keyID = UUID()
        let missing = SecuritySettingsViewModel(state: .keyMissing(keyID: keyID))
        let unavailable = SecuritySettingsViewModel(state: .keyUnavailable(keyID: keyID))

        #expect(missing.canClearInaccessibleHistory)
        #expect(missing.recoveryHelpText.localizedCaseInsensitiveContains("clear inaccessible"))
        #expect(!unavailable.canClearInaccessibleHistory)
        #expect(unavailable.recoveryHelpText.localizedCaseInsensitiveContains("Retry unlock"))
        #expect(unavailable.recoveryHelpText.localizedCaseInsensitiveContains("not the default"))
    }

    @Test
    func ownerAuthenticationCopyDoesNotClaimTouchIDOnly() {
        let available = SecuritySettingsViewModel(state: .locked(keyID: UUID()), canEvaluateOwnerAuthentication: { true })
        let unavailable = SecuritySettingsViewModel(state: .locked(keyID: UUID()), canEvaluateOwnerAuthentication: { false })

        #expect(available.authenticationDescription.localizedCaseInsensitiveContains("Apple Watch"))
        #expect(available.authenticationDescription.localizedCaseInsensitiveContains("password"))
        #expect(!unavailable.authenticationDescription.localizedCaseInsensitiveContains("Touch ID only"))
    }

    @Test
    func unlockRunsAsyncAuthenticatedActionAndUpdatesState() async {
        let recorder = ActionRecorder()
        let keyID = UUID()
        let unlockedState = HistoryLockState.unlocked(keyID: keyID, keyData: Data(repeating: 1, count: 32))
        let viewModel = SecuritySettingsViewModel(
            state: .locked(keyID: keyID),
            actions: actions(recording: recorder, enabledState: unlockedState)
        )

        viewModel.unlock()
        // The unlock action runs on a spawned task; wait for it to finish.
        for _ in 0..<1_000 {
            if recorder.calls == ["unlock"], viewModel.state == unlockedState { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(recorder.calls == ["unlock"])
        #expect(viewModel.state == unlockedState)
    }
}

private final class ActionRecorder {
    var calls = [String]()
}

private func actions(
    recording recorder: ActionRecorder,
    enabledState: HistoryLockState = .locked(keyID: UUID()),
    disabledState: HistoryLockState = .plaintext
) -> SecuritySettingsViewModel.Actions {
    SecuritySettingsViewModel.Actions(
        enableEncryption: {
            recorder.calls.append("enable")
            return enabledState
        },
        disableEncryption: {
            recorder.calls.append("disable")
            return disabledState
        },
        clearInaccessibleHistory: {
            recorder.calls.append("clear")
            return .plaintext
        },
        lockNow: {
            recorder.calls.append("lock")
            return enabledState
        },
        unlock: {
            recorder.calls.append("unlock")
            return enabledState
        }
    )
}
