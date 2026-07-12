//
//  SQLiteDataMigrator+V5.swift
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

extension DatabaseMigrator {
    // swiftlint:disable:next function_body_length
    mutating func registerMigrationV5() {
        registerMigration("Add history security metadata and BLOB text storage") { database in
            try #sql(
                """
                DROP TRIGGER "insert_pasteboardHistories_into_pasteboardHistorySearches"
                """
            )
            .execute(database)

            try #sql(
                """
                DROP TRIGGER "update_pasteboardHistories_in_pasteboardHistorySearches"
                """
            )
            .execute(database)

            try #sql(
                """
                DROP TRIGGER "delete_pasteboardHistories_from_pasteboardHistorySearches"
                """
            )
            .execute(database)

            try #sql(
                """
                DROP TABLE "pasteboardHistorySearches"
                """
            )
            .execute(database)

            try #sql(
                """
                ALTER TABLE "pasteboardHistories"
                ADD COLUMN "titleData" BLOB NOT NULL ON CONFLICT REPLACE DEFAULT X''
                """
            )
            .execute(database)

            try #sql(
                """
                ALTER TABLE "pasteboardHistories"
                ADD COLUMN "ocrTextData" BLOB
                """
            )
            .execute(database)

            try #sql(
                """
                UPDATE "pasteboardHistories"
                SET
                  "titleData" = CAST("title" AS BLOB),
                  "ocrTextData" = CASE
                    WHEN "ocrText" IS NULL THEN NULL
                    ELSE CAST("ocrText" AS BLOB)
                  END
                """
            )
            .execute(database)

            try #sql(
                """
                ALTER TABLE "pasteboardHistories"
                DROP COLUMN "title"
                """
            )
            .execute(database)

            try #sql(
                """
                ALTER TABLE "pasteboardHistories"
                DROP COLUMN "ocrText"
                """
            )
            .execute(database)

            try #sql(
                """
                CREATE TABLE "historySecurityMetadata" (
                  "id" INTEGER PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT 1,
                  "mode" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'plaintext',
                  "formatVersion" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
                  "databaseID" TEXT NOT NULL,
                  "keyID" TEXT,
                  "keyCheck" BLOB,
                  "cleanupGeneration" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
                  CHECK ("id" = 1),
                  CHECK ("mode" IN ('plaintext', 'enablingCleanup', 'encrypted', 'disablingCleanup'))
                ) STRICT
                """
            )
            .execute(database)

            try #sql(
                """
                INSERT INTO "historySecurityMetadata" (
                  "id",
                  "mode",
                  "formatVersion",
                  "databaseID",
                  "keyID",
                  "keyCheck",
                  "cleanupGeneration"
                )
                VALUES (1, 'plaintext', 1, \(UUID().uuidString), NULL, NULL, 0)
                """
            )
            .execute(database)
        }
    }
}
