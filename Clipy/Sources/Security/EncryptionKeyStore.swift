//
//  EncryptionKeyStore.swift
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
import LocalAuthentication
import Security

enum EncryptionKeyStoreError: Error, Equatable {
    case notFound
    case canceled
    case authenticationFailed
    case interactionNotAllowed
    case unavailable
    case unexpected(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecItemNotFound:
            self = .notFound
        case errSecUserCanceled:
            self = .canceled
        case errSecAuthFailed:
            self = .authenticationFailed
        case errSecInteractionNotAllowed:
            self = .interactionNotAllowed
        case errSecNotAvailable:
            self = .unavailable
        default:
            self = .unexpected(status)
        }
    }
}

enum KeyStatus: Equatable {
    case available(UUID)
    case missing(UUID)
    case unavailable(UUID?)
}

struct EncryptionKeyStore {
    var addKey: (_ keyID: UUID, _ keyData: Data) throws -> Void
    var loadKey: (_ keyID: UUID, _ allowsUserInteraction: Bool) throws -> Data
    var deleteKey: (_ keyID: UUID) throws -> Void
    var inventoryKeyIDs: () throws -> [UUID]

    static let live = EncryptionKeyStore(
        addKey: { keyID, keyData in
            let deleteStatus = SecItemDelete(makeDeleteQuery(keyID: keyID) as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw EncryptionKeyStoreError(status: deleteStatus)
            }

            let status = SecItemAdd(makeAddQuery(keyID: keyID, keyData: keyData) as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw EncryptionKeyStoreError(status: status)
            }
        },
        loadKey: { keyID, allowsUserInteraction in
            var query = makeLoadQuery(keyID: keyID)
            if !allowsUserInteraction {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                throw EncryptionKeyStoreError(status: status)
            }
            guard let data = result as? Data else {
                throw EncryptionKeyStoreError.unexpected(errSecInternalError)
            }
            return data
        },
        deleteKey: { keyID in
            let status = SecItemDelete(makeDeleteQuery(keyID: keyID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EncryptionKeyStoreError(status: status)
            }
        },
        inventoryKeyIDs: {
            var query = baseQuery()
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status != errSecItemNotFound else { return [] }
            guard status == errSecSuccess else {
                throw EncryptionKeyStoreError(status: status)
            }

            let rows = result as? [[String: Any]] ?? []
            return rows.compactMap { row in
                guard let account = row[kSecAttrAccount as String] as? String else { return nil }
                return keyID(fromAccount: account)
            }
        }
    )
}

extension EncryptionKeyStore {
    static let service = "com.clipy.history.encryption"
    static let accountPrefix = "history-key."

    static func makeAddQuery(keyID: UUID, keyData: Data) -> [String: Any] {
        var query = baseQuery(keyID: keyID)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return query
    }

    static func makeLoadQuery(keyID: UUID) -> [String: Any] {
        var query = baseQuery(keyID: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static func makeDeleteQuery(keyID: UUID) -> [String: Any] {
        baseQuery(keyID: keyID)
    }

    static func makeInventoryQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        return query
    }

    static func account(for keyID: UUID) -> String {
        accountPrefix + keyID.uuidString.lowercased()
    }

    static func keyID(fromAccount account: String) -> UUID? {
        guard account.hasPrefix(accountPrefix) else { return nil }
        return UUID(uuidString: String(account.dropFirst(accountPrefix.count)))
    }

    static func mapStatus(_ status: OSStatus) -> EncryptionKeyStoreError {
        EncryptionKeyStoreError(status: status)
    }

    private static func baseQuery(keyID: UUID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let keyID {
            query[kSecAttrAccount as String] = account(for: keyID)
        }
        return query
    }
}
