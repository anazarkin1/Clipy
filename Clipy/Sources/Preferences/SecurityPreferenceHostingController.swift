//
//  SecurityPreferenceHostingController.swift
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

@MainActor
final class SecurityPreferenceHostingController: NSHostingController<SecurityPreferenceView> {
    convenience init() {
        self.init(viewModel: SecuritySettingsViewModel())
    }

    init(viewModel: SecuritySettingsViewModel) {
        super.init(rootView: SecurityPreferenceView(viewModel: viewModel))
        preferredContentSize = NSSize(width: 560, height: 360)
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder: NSCoder) {
        nil
    }
}
