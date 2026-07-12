//
//  SecurityPreferenceView.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import SwiftUI

struct SecurityPreferenceView: View {
    @ObservedObject var viewModel: SecuritySettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History Security")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            Text(viewModel.statusMessage)
                .accessibilityLabel(Text("History security status"))
                .accessibilityValue(Text(viewModel.statusMessage))

            Text(viewModel.authenticationDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Authentication options"))

            if !viewModel.recoveryHelpText.isEmpty {
                Text(viewModel.recoveryHelpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Recovery guidance"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Changing encryption clears clipboard history permanently. Snippets are unaffected.")
                    .font(.callout)
                    .accessibilityLabel(Text("Destructive change warning"))

                HStack {
                    Button("Enable Encryption") {
                        viewModel.requestEnable()
                    }
                    .disabled(!viewModel.canEnable)
                    .accessibilityLabel(Text("Enable encrypted clipboard history"))
                    .accessibilityHint(Text("Permanently clears existing clipboard history. Snippets are unaffected."))

                    Button("Disable Encryption") {
                        viewModel.requestDisable()
                    }
                    .disabled(!viewModel.canDisable)
                    .accessibilityLabel(Text("Disable encrypted clipboard history"))
                    .accessibilityHint(Text("Permanently clears encrypted clipboard history. Snippets are unaffected."))
                }
            }

            HStack {
                Button("Lock Now") {
                    viewModel.lockNow()
                }
                .disabled(!viewModel.canLockNow)
                .accessibilityLabel(Text("Lock encrypted history now"))

                Button("Unlock") {
                    viewModel.unlock()
                }
                .disabled(!viewModel.canUnlock)
                .accessibilityLabel(Text("Unlock encrypted history"))

                Button("Clear Inaccessible History") {
                    viewModel.clearInaccessibleHistory()
                }
                .disabled(!viewModel.canClearInaccessibleHistory)
                .accessibilityLabel(Text("Clear inaccessible encrypted history"))
                .accessibilityHint(Text("Available only when the expected encryption key is missing."))
            }

            if viewModel.isTransitioning {
                ProgressView("Updating history security…")
                    .accessibilityLabel(Text("History security update in progress"))
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 560, height: 360, alignment: .topLeading)
        .confirmationDialog(
            "Confirm History Security Change",
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                viewModel.confirmPendingAction()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelConfirmation()
            }
        } message: {
            Text(confirmationMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: LockManager.stateDidChangeNotification)) { _ in
            viewModel.refreshState()
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelConfirmation()
                }
            }
        )
    }

    private var confirmationMessage: String {
        switch viewModel.pendingConfirmation {
        case .enable:
            return viewModel.enableConfirmationText
        case .disable:
            return viewModel.disableConfirmationText
        case nil:
            return ""
        }
    }
}
