//
//  HistoryKeyCheckTests.swift
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

@Suite
struct HistoryKeyCheckTests {
    @Test
    func keyCheckVerifiesOnlyMatchingKeyIDAndDatabaseID() {
        let key = Data(repeating: 0x11, count: 32)
        let wrongKey = Data(repeating: 0x22, count: 32)
        let keyID = UUID()
        let databaseID = UUID()

        let check = HistoryKeyCheck.make(rootKey: key, keyID: keyID, databaseID: databaseID)

        #expect(HistoryKeyCheck.isWellFormed(check))
        #expect(HistoryKeyCheck.verify(check, rootKey: key, keyID: keyID, databaseID: databaseID))
        #expect(!HistoryKeyCheck.verify(check, rootKey: wrongKey, keyID: keyID, databaseID: databaseID))
        #expect(!HistoryKeyCheck.verify(check, rootKey: key, keyID: UUID(), databaseID: databaseID))
        #expect(!HistoryKeyCheck.verify(check, rootKey: key, keyID: keyID, databaseID: UUID()))
    }

    @Test
    func malformedKeyCheckIsRejected() {
        let key = Data(repeating: 0x11, count: 32)
        let keyID = UUID()
        let databaseID = UUID()
        let check = HistoryKeyCheck.make(rootKey: key, keyID: keyID, databaseID: databaseID)

        #expect(!HistoryKeyCheck.isWellFormed(Data()))
        #expect(!HistoryKeyCheck.isWellFormed(Data([0x43, 0x50, 0x59, 0x4b, 0x02]) + check.suffix(32)))
        #expect(!HistoryKeyCheck.verify(Data([0x00]), rootKey: key, keyID: keyID, databaseID: databaseID))
    }
}
