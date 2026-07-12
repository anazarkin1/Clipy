//
//  EncryptionEnvelope.swift
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

struct EncryptionEnvelope: Equatable {
    static let currentVersion: UInt8 = 1
    static let maxEnvelopeSize = 64 * 1024 * 1024

    private static let magic = Data([0x43, 0x50, 0x59, 0x45])

    let version: UInt8
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    init(version: UInt8 = Self.currentVersion, nonce: Data, ciphertext: Data, tag: Data) {
        self.version = version
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    init(serialized data: Data) throws {
        guard data.count <= Self.maxEnvelopeSize else {
            throw EncryptionEnvelopeError.oversized
        }
        var cursor = 0
        guard try data.readData(count: Self.magic.count, cursor: &cursor) == Self.magic else {
            throw EncryptionEnvelopeError.malformed
        }

        let version = try data.readUInt8(cursor: &cursor)
        guard version == Self.currentVersion else {
            throw EncryptionEnvelopeError.unknownVersion(version)
        }

        let nonceLength = Int(try data.readUInt16(cursor: &cursor))
        let tagLength = Int(try data.readUInt16(cursor: &cursor))
        let ciphertextLength = Int(try data.readUInt64(cursor: &cursor))
        guard nonceLength > 0, tagLength > 0, ciphertextLength >= 0 else {
            throw EncryptionEnvelopeError.malformed
        }

        let nonce = try data.readData(count: nonceLength, cursor: &cursor)
        let ciphertext = try data.readData(count: ciphertextLength, cursor: &cursor)
        let tag = try data.readData(count: tagLength, cursor: &cursor)
        guard cursor == data.count else {
            throw EncryptionEnvelopeError.malformed
        }

        self.version = version
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    var serialized: Data {
        var data = Data()
        data.append(Self.magic)
        data.append(version)
        data.appendUInt16(UInt16(nonce.count))
        data.appendUInt16(UInt16(tag.count))
        data.appendUInt64(UInt64(ciphertext.count))
        data.append(nonce)
        data.append(ciphertext)
        data.append(tag)
        return data
    }

    var sealedBox: AES.GCM.SealedBox {
        get throws {
            try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
        }
    }
}

enum EncryptionEnvelopeError: Error, Equatable {
    case malformed
    case oversized
    case truncated
    case unknownVersion(UInt8)
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readUInt8(cursor: inout Int) throws -> UInt8 {
        guard let byte = try readData(count: 1, cursor: &cursor).first else {
            throw EncryptionEnvelopeError.truncated
        }
        return byte
    }

    func readUInt16(cursor: inout Int) throws -> UInt16 {
        let bytes = try readData(count: 2, cursor: &cursor)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    func readUInt64(cursor: inout Int) throws -> UInt64 {
        let bytes = try readData(count: 8, cursor: &cursor)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    func readData(count: Int, cursor: inout Int) throws -> Data {
        guard count >= 0, cursor + count <= self.count else {
            throw EncryptionEnvelopeError.truncated
        }
        let range = cursor..<(cursor + count)
        cursor += count
        return subdata(in: range)
    }
}
