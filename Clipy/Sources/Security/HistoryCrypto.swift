//
//  HistoryCrypto.swift
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

struct HistoryCrypto {
    private let encryptionKey: SymmetricKey
    private let fingerprintKey: SymmetricKey

    init(rootKey: SymmetricKey, databaseID: UUID) {
        self.encryptionKey = Self.deriveKey(
            rootKey: rootKey,
            databaseID: databaseID,
            info: "com.clipy.history.encryption.v1"
        )
        self.fingerprintKey = Self.deriveKey(
            rootKey: rootKey,
            databaseID: databaseID,
            info: "com.clipy.history.fingerprint.v1"
        )
    }

    func seal(_ plaintext: Data, context: EncryptionContext) throws -> Data {
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: encryptionKey,
            authenticating: context.authenticatedData
        )
        return EncryptionEnvelope(
            nonce: Data(sealedBox.nonce),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        .serialized
    }

    func open(_ serializedEnvelope: Data, context: EncryptionContext) throws -> Data {
        let envelope = try EncryptionEnvelope(serialized: serializedEnvelope)
        return try AES.GCM.open(
            envelope.sealedBox,
            using: encryptionKey,
            authenticating: context.authenticatedData
        )
    }

    func fingerprintID(for canonicalContent: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: canonicalContent,
            using: fingerprintKey
        )
        return Data(code).hexString
    }

    func exportedSubkeysForTesting() -> (encryption: Data, fingerprint: Data) {
        (
            encryptionKey.withUnsafeBytes { Data($0) },
            fingerprintKey.withUnsafeBytes { Data($0) }
        )
    }

    private static func deriveKey(rootKey: SymmetricKey, databaseID: UUID, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootKey,
            salt: Data(databaseID),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }
}

private extension Data {
    init(_ uuid: UUID) {
        var uuid = uuid.uuid
        self = Swift.withUnsafeBytes(of: &uuid) { Data($0) }
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
