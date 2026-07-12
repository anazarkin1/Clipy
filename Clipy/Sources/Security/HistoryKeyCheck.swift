//
//  HistoryKeyCheck.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import CryptoKit
import Foundation

enum HistoryKeyCheck {
    private static let magic = Data([0x43, 0x50, 0x59, 0x4b])
    private static let version: UInt8 = 1
    private static let macLength = 32

    static func make(rootKey: Data, keyID: UUID, databaseID: UUID) -> Data {
        magic + Data([version]) + mac(rootKey: rootKey, keyID: keyID, databaseID: databaseID)
    }

    static func isWellFormed(_ data: Data) -> Bool {
        data.count == magic.count + 1 + macLength
            && data.prefix(magic.count) == magic
            && data[magic.count] == version
    }

    static func verify(_ data: Data, rootKey: Data, keyID: UUID, databaseID: UUID) -> Bool {
        guard isWellFormed(data) else { return false }
        return data == make(rootKey: rootKey, keyID: keyID, databaseID: databaseID)
    }

    private static func mac(rootKey: Data, keyID: UUID, databaseID: UUID) -> Data {
        var message = Data("com.clipy.history.key-check.v1".utf8)
        message.append(uuidData(databaseID))
        message.append(uuidData(keyID))

        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: rootKey)
        )
        return Data(code)
    }

    private static func uuidData(_ uuid: UUID) -> Data {
        var uuid = uuid.uuid
        return Swift.withUnsafeBytes(of: &uuid) { Data($0) }
    }
}
