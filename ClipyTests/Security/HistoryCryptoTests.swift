//
//  HistoryCryptoTests.swift
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
import Testing
@testable import Clipy

@Suite
struct HistoryCryptoTests {
    private let databaseID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let rootKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    @Test
    func supportedContextsRoundTrip() throws {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let plaintext = Data("secret clipboard value".utf8)

        for context in supportedContexts {
            let sealed = try crypto.seal(plaintext, context: context)
            let opened = try crypto.open(sealed, context: context)
            #expect(opened == plaintext)
        }
    }

    @Test
    func changingAuthenticatedContextFails() throws {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let plaintext = Data("context bound value".utf8)
        let context = historyContext()
        let sealed = try crypto.seal(plaintext, context: context)

        let changedContexts = [
            historyContext(databaseID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!),
            historyContext(tableName: "OtherTable"),
            historyContext(columnName: "ocrTextData"),
            historyContext(historyID: "history-2"),
            historyContext(assetID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!),
            historyContext(assetIndex: 7),
            historyContext(pasteboardType: "public.png"),
            historyContext(thumbnailKind: "colorCode")
        ]

        for changedContext in changedContexts {
            #expect(catchesError { try crypto.open(sealed, context: changedContext) })
        }
    }

    @Test
    func swappingValidEnvelopesBetweenRowsOrColumnsFails() throws {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let firstContext = historyContext(columnName: "titleData", historyID: "history-1")
        let secondContext = historyContext(columnName: "titleData", historyID: "history-2")
        let columnContext = historyContext(columnName: "ocrTextData", historyID: "history-1")

        let firstEnvelope = try crypto.seal(Data("first".utf8), context: firstContext)
        let secondEnvelope = try crypto.seal(Data("second".utf8), context: secondContext)

        #expect(catchesError { try crypto.open(firstEnvelope, context: secondContext) })
        #expect(catchesError { try crypto.open(secondEnvelope, context: firstContext) })
        #expect(catchesError { try crypto.open(firstEnvelope, context: columnContext) })
    }

    @Test
    func malformedEnvelopesFailClosed() throws {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let context = historyContext()
        let sealed = try crypto.seal(Data("secret".utf8), context: context)

        #expect(catchesError { try EncryptionEnvelope(serialized: Data("not-an-envelope".utf8)) })
        #expect(catchesError { try EncryptionEnvelope(serialized: Data(sealed.prefix(8))) })

        var unknownVersion = sealed
        unknownVersion[4] = 99
        #expect(caughtEnvelopeError { try EncryptionEnvelope(serialized: unknownVersion) } == .unknownVersion(99))

        let oversized = Data(count: EncryptionEnvelope.maxEnvelopeSize + 1)
        #expect(caughtEnvelopeError { try EncryptionEnvelope(serialized: oversized) } == .oversized)

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        #expect(catchesError { try crypto.open(tampered, context: context) })
    }

    @Test
    func repeatedEncryptionsUseFreshNonces() throws {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let context = historyContext()
        let plaintext = Data("same value".utf8)
        var nonces = Set<Data>()

        for _ in 0..<10_000 {
            let sealed = try crypto.seal(plaintext, context: context)
            let envelope = try EncryptionEnvelope(serialized: sealed)
            #expect(nonces.insert(envelope.nonce).inserted)
            #expect(try crypto.open(sealed, context: context) == plaintext)
        }
    }

    @Test
    func derivedSubkeysDiffer() {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let subkeys = crypto.exportedSubkeysForTesting()

        #expect(subkeys.encryption.count == 32)
        #expect(subkeys.fingerprint.count == 32)
        #expect(subkeys.encryption != subkeys.fingerprint)
    }

    @Test
    func hmacFingerprintIDIsStableAndNotPlaintextSHA256() {
        let crypto = HistoryCrypto(rootKey: rootKey, databaseID: databaseID)
        let canonical = Data("public.utf8-plain-text\\0hello".utf8)
        let changedByte = Data("public.utf8-plain-text\\0hellp".utf8)
        let changedType = Data("public.rtf\\0hello".utf8)
        let changedOrder = Data("hello\\0public.utf8-plain-text".utf8)

        let first = crypto.fingerprintID(for: canonical)
        #expect(first == crypto.fingerprintID(for: canonical))
        #expect(first != crypto.fingerprintID(for: changedByte))
        #expect(first != crypto.fingerprintID(for: changedType))
        #expect(first != crypto.fingerprintID(for: changedOrder))
        #expect(first != plaintextSHA256Hex(canonical))
    }
}

private extension HistoryCryptoTests {
    var supportedContexts: [EncryptionContext] {
        [
            historyContext(tableName: "pasteboardHistories", columnName: "titleData"),
            historyContext(tableName: "pasteboardHistories", columnName: "ocrTextData"),
            historyContext(
                tableName: "pasteboardHistoryAssets",
                columnName: "data",
                assetID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                assetIndex: 0,
                pasteboardType: "public.utf8-plain-text"
            ),
            historyContext(
                tableName: "pasteboardHistoryThumbnailAssets",
                columnName: "data",
                thumbnailKind: "image"
            )
        ]
    }

    func historyContext(
        databaseID: UUID? = nil,
        tableName: String = "pasteboardHistories",
        columnName: String = "titleData",
        historyID: String = "history-1",
        assetID: UUID? = nil,
        assetIndex: Int? = nil,
        pasteboardType: String? = nil,
        thumbnailKind: String? = nil
    ) -> EncryptionContext {
        EncryptionContext(
            databaseID: databaseID ?? self.databaseID,
            tableName: tableName,
            columnName: columnName,
            historyID: historyID,
            assetID: assetID,
            assetIndex: assetIndex,
            pasteboardType: pasteboardType,
            thumbnailKind: thumbnailKind
        )
    }

    func plaintextSHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).withUnsafeBytes { bytes in
            Data(bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    func catchesError<T>(_ operation: () throws -> T) -> Bool {
        do {
            _ = try operation()
            return false
        } catch {
            return true
        }
    }

    func caughtEnvelopeError<T>(_ operation: () throws -> T) -> EncryptionEnvelopeError? {
        do {
            _ = try operation()
            return nil
        } catch let error as EncryptionEnvelopeError {
            return error
        } catch {
            return nil
        }
    }
}
