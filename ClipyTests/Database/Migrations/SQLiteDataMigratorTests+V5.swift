//
//  SQLiteDataMigratorTests+V5.swift
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
import SQLiteData
import Testing
@testable import Clipy

extension SQLiteDataMigratorTests {
    @Test
    func migrationV5() throws {
        let database = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigrationV1()
        migrator.registerMigrationV2()
        migrator.registerMigrationV3()
        migrator.registerMigrationV4()

        try migrator.migrate(database)
        try seedV4History(database)

        migrator.registerMigrationV5()
        try migrator.migrate(database)

        try expectV5Tables(database)
        try expectV5Metadata(database)
        try expectV5RemovesHistorySearch(database)
        try expectV5PreservesPlaintextHistory(database)
    }

    func expectV5Tables(_ database: DatabaseQueue) throws {
        try database.read { database in
            let columnNames = try columnNames(of: "pasteboardHistories", database: database)
            #expect(
                columnNames == [
                    "createdAt",
                    "deviceID",
                    "id",
                    "ocrTextData",
                    "pasteboardTypes",
                    "titleData",
                    "updateAt"
                ]
            )
        }
        try database.read { database in
            let columnNames = try columnNames(of: "historySecurityMetadata", database: database)
            #expect(
                columnNames == [
                    "cleanupGeneration",
                    "databaseID",
                    "formatVersion",
                    "id",
                    "keyCheck",
                    "keyID",
                    "mode"
                ]
            )
        }
    }

    func expectV5Metadata(_ database: DatabaseQueue) throws {
        try database.read { database in
            let metadata = try #sql(
                """
                SELECT "mode", "formatVersion", "keyID", "keyCheck", "cleanupGeneration"
                FROM "historySecurityMetadata"
                WHERE "id" = 1
                """,
                as: (String, Int, String?, Data?, Int).self
            )
            .fetchOne(database)

            #expect(metadata?.0 == "plaintext")
            #expect(metadata?.1 == 1)
            #expect(metadata?.2 == nil)
            #expect(metadata?.3 == nil)
            #expect(metadata?.4 == 0)

            let databaseID = try #require(
                #sql(
                    """
                    SELECT "databaseID"
                    FROM "historySecurityMetadata"
                    WHERE "id" = 1
                    """,
                    as: String.self
                )
                .fetchOne(database)
            )
            #expect(UUID(uuidString: databaseID) != nil)
        }
    }

    func expectV5RemovesHistorySearch(_ database: DatabaseQueue) throws {
        try database.read { database in
            let historySearchTables = try #sql(
                """
                SELECT "name"
                FROM "sqlite_schema"
                WHERE "name" LIKE 'pasteboardHistorySearches%'
                ORDER BY "name"
                """,
                as: String.self
            )
            .fetchAll(database)
            #expect(historySearchTables == [])

            let historyTriggers = try #sql(
                """
                SELECT "name"
                FROM "sqlite_schema"
                WHERE "type" = 'trigger'
                AND "tbl_name" = 'pasteboardHistories'
                ORDER BY "name"
                """,
                as: String.self
            )
            .fetchAll(database)
            #expect(historyTriggers == [])
        }
    }

    func expectV5PreservesPlaintextHistory(_ database: DatabaseQueue) throws {
        try database.read { database in
            let history = try #require(PasteboardHistory.find(PasteboardHistory.ID(rawValue: "history-1")).fetchOne(database))
            #expect(history.title == "Plaintext Title")
            #expect(history.ocrText == "Plaintext OCR")
            #expect(history.pasteboardTypes == [.string])
            #expect(history.createdAt == 1)
            #expect(history.updateAt == 2)

            let rawData = try #sql(
                """
                SELECT "titleData", "ocrTextData"
                FROM "pasteboardHistories"
                WHERE "id" = 'history-1'
                """,
                as: (Data, Data?).self
            )
            .fetchOne(database)
            #expect(rawData?.0 == Data("Plaintext Title".utf8))
            #expect(rawData?.1 == Data("Plaintext OCR".utf8))
        }
    }

    func seedV4History(_ database: DatabaseQueue) throws {
        try database.write { database in
            try #sql(
                """
                INSERT INTO "pasteboardHistories" (
                  "id",
                  "title",
                  "ocrText",
                  "pasteboardTypes",
                  "createdAt",
                  "updateAt",
                  "deviceID"
                )
                VALUES (
                  'history-1',
                  'Plaintext Title',
                  'Plaintext OCR',
                  '["public.utf8-plain-text"]',
                  1,
                  2,
                  NULL
                )
                """
            )
            .execute(database)
        }
    }
}
