# Implementation Spec: Synchronous `VACUUM` on Clear History

## Objective

When the user invokes **Clear History**, reclaim the disk space freed by the
deletion. Today the SQLite store (`~/Library/Application Support/<bundleID>/sqlite.db`)
never shrinks under normal use: `PRAGMA auto_vacuum` is `0` (off) and the only
`VACUUM` in the codebase runs solely during encryption-mode transitions. A real
user's file was observed at **1.97 GB with 0 history rows** (99.99% free pages)
because deleted image history is never compacted.

This change runs `VACUUM` **synchronously** right after a full clear.

**Decision (2026-07-20): everything stays on the main thread.** `deleteAll()`
is already a synchronous main-thread write, and the VACUUM that follows a full
clear copies ~zero live rows, so it completes in milliseconds. The added
main-thread cost of the VACUUM is negligible; async dispatch, coalescing
guards, and completion plumbing were considered and rejected as unnecessary
complexity for this trigger. (The delete itself can be slow on a multi-GB
database — that is pre-existing behavior and explicitly out of scope here.)

## Scope / Non-goals

- **In scope:** compaction only for the *clear-all* action (`ClipService.clearAll()`).
- **Out of scope (intentionally):**
  - No async/off-main-thread execution of the compaction (see Decision above).
  - No change to `deleteAll()` or its threading.
  - No `PRAGMA auto_vacuum = INCREMENTAL` migration.
  - No periodic/timer-based VACUUM.
  - No compaction on the routine size-cap trim
    (`deleteOverflowingHistories(maxHistorySize:)` with `maxHistorySize > 0`).
  - No threshold gating (freelist-ratio checks). Not needed for the clear-all
    trigger because that path deletes everything.

These were considered and rejected as heavier/riskier than the explicit
Clear-History trigger. Do not add them here.

## Why the clear-all trigger is the safe (and cheap) place to VACUUM

`VACUUM` rebuilds the whole database file by copying **live** rows into a fresh
file, so its cost scales with *remaining live data*, not with how much was
deleted. After `clearAll()`:

- `deleteAll()` deletes every `pasteboardHistories` row.
- `pasteboardHistoryAssets` and `pasteboardHistoryThumbnailAssets` both declare
  `FOREIGN KEY ("pasteboardHistoryID") REFERENCES "pasteboardHistories"("id") ON DELETE CASCADE`.
  GRDB enables foreign keys by default, so both cascade away.
- Remaining live history data ≈ 0 → the VACUUM copy is tiny and finishes in
  milliseconds with a negligible temp file. This is what makes the synchronous
  main-thread call acceptable.

(The `snippets`/`snippetFolders` tables are small plaintext and not affected by
Clear History; they add trivial live data to the rebuild.)

Doing the same VACUUM on the routine size-cap trim would be the opposite: a
full-file rewrite of gigabytes of *still-live* images, far too slow to run
synchronously. That is why compaction is attached to the clear-all semantic in
`ClipService`, not to the low-level `deleteAll()` (which is also called by the
trim path with `maxHistorySize == 0`).

## Environment facts (verified)

- GRDB **7.10.0** (via SQLiteData). The DB handle is injected as
  `@Dependency(\.defaultDatabase)` (an `any DatabaseWriter`), configured in
  `Clipy/Sources/Database/SQLiteDataDatabase.swift`. Journal mode is **WAL**.
- **`VACUUM` cannot run inside a transaction** — it must use the synchronous
  `writeWithoutTransaction { db in ... }` API, not `database.write { }` (which
  opens a transaction).
- Proven sequence already in the codebase:
  `Clipy/Sources/Security/HistorySecurityCoordinator.swift` →
  `cleanupStorage()` runs `PRAGMA wal_checkpoint(TRUNCATE)` in one
  `writeWithoutTransaction`, then `VACUUM` in a second `writeWithoutTransaction`.
  Mirror this ordering. (The checkpoint is not required for VACUUM to reclaim
  pages — VACUUM rebuilds the file and resets the WAL on its own — but it
  shrinks the `-wal` file promptly and keeps the two call sites consistent.)
- **Only one conformer** of `PasteboardHistoryRepositoryProtocol` exists (the
  real `PasteboardHistoryRepository`). No mocks/stubs/test-doubles to update.
  Tests exercise the real repository against a temp DB via the Dependencies
  system.

## Files to change

1. `Clipy/Sources/Repositories/PasteboardHistoryRepository.swift`
2. `Clipy/Sources/Services/ClipService.swift`
3. `ClipyTests/Repositories/PasteboardHistoryRepositoryTests.swift`

> ⚠️ The working tree at `/Users/alex/Clipy` (branch `develop`) also contains
> uncommitted encryption/LockManager work from a concurrent agent. Touch **only**
> the three files above. Do not revert or restage anything else.

---

## Change 1 — `PasteboardHistoryRepository.swift`

### 1a. Protocol addition

Add to `PasteboardHistoryRepositoryProtocol` (near the other mutating ops such as
`deleteAll()`):

```swift
/// Rebuilds the database file to reclaim pages freed by a full clear.
///
/// Runs synchronously on the caller's thread; intended to be called
/// immediately after `deleteAll()`, when almost no live data remains and the
/// rebuild takes milliseconds. Not used by the routine size-cap trim, where a
/// full-file rebuild of still-live data would be expensive.
func compactStorage()
```

### 1b. Implementation

No locks, no flags, no async dispatch — a plain synchronous call:

```swift
func compactStorage() {
    withErrorReporting {
        try database.writeWithoutTransaction { database in
            try Self.performCompaction(database)
        }
    }
}
```

Synchronous core (kept separate so tests can call it against their own writer):

```swift
static func performCompaction(_ db: Database) throws {
    try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    try db.execute(sql: "VACUUM")
}
```

Implementation notes for whoever writes this:

- `withErrorReporting` is the same helper used throughout this file (import
  already present via SQLiteData/Dependencies). A failure (e.g. `SQLITE_FULL`)
  must be swallowed/logged, never fatal — the file simply stays large.
- `wal_checkpoint(TRUNCATE)` does not throw on contention: if a reader
  connection holds a snapshot it returns a `busy=1` row and skips truncation.
  That is fine — the VACUUM still reclaims the main file either way.
- **Never log query/clipboard content.** There is none in this path, but keep it
  that way (no interpolating row data into errors).
- `performCompaction` is `static` so it holds no `self` and is trivially
  callable from tests.

### 1c. Cascade / foreign-keys sanity

No code change, but verify foreign keys are ON for the connection (GRDB default
is ON). If for any reason they were disabled, `deleteAll()` would orphan asset
rows and the VACUUM would keep them as live data. The existing
`PasteboardHistoryRepositoryTests` should already implicitly rely on cascade; do
not add a separate pragma toggle.

---

## Change 2 — `ClipService.swift`

Current `clearAll()`:

```swift
func clearAll() {
    pasteboardHistoryRepository.deleteAll()
    // Clear legacy Realm-backed history caches used through v1.2.1.
    PINCache.shared.removeAllObjects()
    try? FileManager.default.removeItem(atPath: CPYUtilities.applicationSupportFolder())
}
```

Change to:

```swift
func clearAll() {
    pasteboardHistoryRepository.deleteAll()
    // Reclaim the pages the clear just freed. Synchronous and cheap here:
    // VACUUM cost scales with surviving data, which is ~zero after a full clear.
    pasteboardHistoryRepository.compactStorage()
    // Clear legacy Realm-backed history caches used through v1.2.1.
    PINCache.shared.removeAllObjects()
    try? FileManager.default.removeItem(atPath: CPYUtilities.applicationSupportFolder())
}
```

Ordering rationale: `deleteAll()` uses the sync `database.write` (a transaction
that commits before returning). `compactStorage()` then runs on the same writer,
so it observes the committed delete. Both writes are serialized by GRDB's single
writer queue; the calls simply block the caller until each finishes.

---

## Change 3 — Tests (`PasteboardHistoryRepositoryTests.swift`)

Add a deterministic reclamation test. Everything is synchronous now, so the
test can call `repository.compactStorage()` directly — no polling or
expectations needed.

Test outline:

1. Insert several histories, each with a large BLOB asset (e.g. a few hundred KB
   of `Data`) so the file grows to many pages. Follow the existing test file's
   setup for constructing a temp DB + repository via Dependencies.
2. Read baseline `PRAGMA page_count` and `PRAGMA freelist_count`
   (`try db.read { ... Int.self ... }`).
3. Call `repository.deleteAll()`.
4. Read `freelist_count` again — assert it is now **> 0** (delete freed pages but
   did not reclaim them; proves the "grows forever" behavior we are fixing).
5. Call `repository.compactStorage()`.
6. Assert post-compaction `freelist_count == 0` **and** `page_count` dropped
   substantially versus the pre-delete baseline.

Notes:

- The suite uses Swift Testing (`@Test`/`#expect`) — match that style.
- `performCompaction` remains available for a lower-level test against a bare
  writer if useful, but testing through `compactStorage()` is now equally
  deterministic and exercises the production path. `internal` visibility with
  `@testable import Clipy` is enough — do **not** make anything `public`.

---

## Concurrency & safety summary (for reviewer)

- **Thread:** both the delete and the VACUUM run synchronously on the caller's
  (main) thread. This is a deliberate decision: post-clear VACUUM is
  milliseconds. The pre-existing cost of `deleteAll()` on a multi-GB database
  is unchanged by this spec.
- **Serialization:** GRDB serializes all writes on a single writer. The VACUUM
  cannot corrupt or interleave with a clipboard-capture write; worst case it
  waits its turn (or an in-flight write briefly delays it).
- **Repeated Clear:** a second Clear runs a second VACUUM against an
  already-empty database — a millisecond no-op. No coalescing guard is needed.
- **Failure mode:** on `SQLITE_FULL` (or any error) the operation is logged and
  abandoned; the DB remains valid, just uncompacted. Never crashes.
- **Security bonus:** VACUUM rewrites the file and drops freed pages, so deleted
  *ciphertext* pages don't linger in the live file (same benefit the encryption
  coordinator already relies on). Caveat: on SSDs this does not guarantee
  *physical* overwrite (wear-leveling); do not describe it as secure erase.

## Manual verification

1. Build & run; accumulate history including a few large images so `sqlite.db`
   is clearly multi-hundred-MB (`stat -f%z`).
2. Clear History from the menu.
3. Confirm the app remains responsive immediately after the clear completes
   (the delete itself may take a moment on a very large DB — pre-existing).
4. Re-check the file size — it should collapse to a few KB / pages. Cross-check:
   `sqlite3 sqlite.db "PRAGMA page_count; PRAGMA freelist_count;"` →
   `freelist_count` should be `0`.

## Acceptance criteria

- [ ] `compactStorage()` added to protocol + implemented as a synchronous call.
- [ ] Called from `ClipService.clearAll()` after `deleteAll()`.
- [ ] Routine trim path (`deleteOverflowingHistories(maxHistorySize:>0)`) unchanged.
- [ ] No async dispatch, locks, or coalescing state introduced.
- [ ] VACUUM failure is non-fatal.
- [ ] New test proves `freelist_count == 0` and `page_count` shrinks after
      delete + compaction.
- [ ] Only the three listed files changed.
