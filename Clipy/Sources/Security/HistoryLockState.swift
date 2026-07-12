//
//  HistoryLockState.swift
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

enum HistorySecurityMode: String {
    case plaintext
    case enablingCleanup
    case encrypted
    case disablingCleanup
}

enum HistoryLockState: Equatable {
    case plaintext
    case blockedByOrphanKeys([UUID])
    case locked(keyID: UUID)
    case unlocked(keyID: UUID, keyData: Data)
    case keyMissing(keyID: UUID)
    case keyUnavailable(keyID: UUID?)
    case corrupt(String)

    var allowsHistoryServices: Bool {
        switch self {
        case .plaintext, .unlocked:
            true
        case .blockedByOrphanKeys, .locked, .keyMissing, .keyUnavailable, .corrupt:
            false
        }
    }

    var allowsRealmHistoryImport: Bool {
        self == .plaintext
    }
}
