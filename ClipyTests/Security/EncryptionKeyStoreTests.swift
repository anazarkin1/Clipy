//
//  EncryptionKeyStoreTests.swift
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
import Security
import Testing
@testable import Clipy

@Suite
struct EncryptionKeyStoreTests {
    @Test
    func keychainQueriesUseDataProtectionKeychain() {
        let keyID = UUID()
        let keyData = Data(repeating: 0xa5, count: 32)

        let addQuery = EncryptionKeyStore.makeAddQuery(keyID: keyID, keyData: keyData)
        let loadQuery = EncryptionKeyStore.makeLoadQuery(keyID: keyID)
        let deleteQuery = EncryptionKeyStore.makeDeleteQuery(keyID: keyID)
        let inventoryQuery = EncryptionKeyStore.makeInventoryQuery()

        for query in [addQuery, loadQuery, deleteQuery, inventoryQuery] {
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == EncryptionKeyStore.service)
        }

        #expect(addQuery[kSecAttrAccount as String] as? String == EncryptionKeyStore.account(for: keyID))
        #expect(addQuery[kSecValueData as String] as? Data == keyData)
        #expect(addQuery[kSecAttrAccessControl as String] != nil)

        #expect(loadQuery[kSecReturnData as String] as? Bool == true)
        #expect(loadQuery[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)

        #expect(inventoryQuery[kSecReturnAttributes as String] as? Bool == true)
        #expect(inventoryQuery[kSecReturnData as String] == nil)
    }

    @Test
    func statusMappingPreservesDistinctKeychainErrors() {
        #expect(EncryptionKeyStore.mapStatus(errSecItemNotFound) == .notFound)
        #expect(EncryptionKeyStore.mapStatus(errSecUserCanceled) == .canceled)
        #expect(EncryptionKeyStore.mapStatus(errSecAuthFailed) == .authenticationFailed)
        #expect(EncryptionKeyStore.mapStatus(errSecInteractionNotAllowed) == .interactionNotAllowed)
        #expect(EncryptionKeyStore.mapStatus(errSecNotAvailable) == .unavailable)
        #expect(EncryptionKeyStore.mapStatus(errSecDuplicateItem) == .unexpected(errSecDuplicateItem))
    }

    @Test
    func inventoryParsesOnlyClipyHistoryKeyAccounts() {
        let keyID = UUID()

        #expect(EncryptionKeyStore.keyID(fromAccount: EncryptionKeyStore.account(for: keyID)) == keyID)
        #expect(EncryptionKeyStore.keyID(fromAccount: "history-key.not-a-uuid") == nil)
        #expect(EncryptionKeyStore.keyID(fromAccount: "other.\(keyID.uuidString)") == nil)
    }
}
