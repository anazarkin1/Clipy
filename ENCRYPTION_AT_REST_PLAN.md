# Clipy — Encrypted Clipboard History at Rest (Implementation Plan)

> Technical guidance for an implementing engineer or model. Read this whole
> document before writing code. It is written against the current develop branch.

---

## 1. Goal

Protect clipboard-history contents on disk so that a lost, stolen, stopped, or
offline copy of the machine cannot reveal what the user copied.

Concretely:

1. Encrypt sensitive clipboard-history columns with application-level
   AES-256-GCM using CryptoKit. Do not add a third-party cryptography dependency.
2. Protect the master key with macOS Keychain user-presence authentication.
   Unlock once per application session and keep the unlocked key only in memory.
3. Always re-lock on screen/session lock and system sleep. Optionally re-lock
   after a configurable idle timeout.
4. Treat changing security mode as destructive:
   - Enabling encryption clears all existing plaintext clipboard history.
   - Disabling encryption clears all existing encrypted clipboard history.
   - Do not migrate history values between plaintext and encrypted formats.

### Explicit non-goals and accepted tradeoffs

- While Clipy is running and unlocked, decrypted values and the key may exist in
  process memory. Clipy is unsandboxed, so this design does not protect against a
  same-user process capable of reading or injecting into Clipy's memory.
- Encryption is opt-in and off by default.
- Existing Time Machine backups, APFS snapshots, SSD remanence, and other
  previously created copies cannot be retroactively protected. Enabling
  encryption scrubs the active database on a best-effort basis only.
- The key is ThisDeviceOnly and cannot migrate to a replacement Mac. If the
  Keychain item is lost or reset, encrypted history is intentionally
  unrecoverable. The app must fail closed and offer to clear inaccessible
  history; it must never silently fall back to plaintext.
- iCloud/CloudKit history sync is incompatible with a ThisDeviceOnly key. Keep
  encrypted history and history sync mutually exclusive.
- This plan protects clipboard history only. Snippets remain outside this scope.

---

## 2. Current architecture

- Database stack: pointfreeco/sqlite-data, GRDB, and SQLite. The database is
  created in SQLiteDataDatabase.bootstrapDatabase() and stored at
  Application Support/<bundle-id>/sqlite.db.
- Repository seam: PasteboardHistoryRepository owns normal clipboard-history
  reads and writes. Encryption and decryption for ordinary operations belong
  here.
- Relevant tables:
  - PasteboardHistory: id, title, ocrText, pasteboardTypes, timestamps, deviceID.
  - PasteboardHistoryAsset: the original clipboard bytes.
  - PasteboardHistoryThumbnailAsset: a rendered thumbnail that can reveal content.
  - PasteboardHistorySearch: an FTS5 index containing title and OCR text.
- Important correction: history FTS is actively maintained by triggers in
  SQLiteDataMigrator+V2 and SQLiteDataMigrator+V4. It is not merely a dormant
  schema declaration. Because encrypted SQL search is out of scope, remove the
  history FTS table and its triggers when adding encrypted history. Snippet FTS
  is unrelated and remains.
- Capture path: ClipService polls NSPasteboard.general and calls repository.save,
  followed by asynchronous OCR through TextRecognizer.
- Dependency injection: follow the existing swift-dependencies DependencyKey
  pattern for security services and their test/preview values.
- Preferences: defaults are registered in CPYUtilities and preference panels
  currently mix AppKit, RxSwift, Combine, and XIBs.
- Legacy storage: DatabaseMigration reads old Realm metadata and per-clip archive
  files. ClipService.clearAll removes legacy caches, but a successful Realm-to-
  SQLite migration does not currently remove all legacy plaintext artifacts.

---

## 3. Storage schema and security metadata

Do not infer encryption state from user-controlled bytes. Do not use a one-byte
prefix to distinguish plaintext from ciphertext.

Add a singleton HistorySecurityMetadata table with at least:

| Column | Purpose |
|---|---|
| mode | plaintext, enablingCleanup, encrypted, or disablingCleanup |
| formatVersion | Current encrypted-record format |
| databaseID | Random UUID used in authenticated context |
| keyID | UUID identifying the expected Keychain key; null in plaintext mode |
| keyCheck | Authenticated fixed-value envelope proving the key and metadata match |
| cleanupGeneration | Monotonic value for idempotent transition recovery |

The database mode is authoritative. Keychain lookup results are not a substitute
for mode. Mode, keyID, the Keychain inventory, and keyCheck must agree before
ordinary history access starts. A mismatch is a transition, inaccessible, or
corrupt state rather than permission to use plaintext.

Change sensitive string storage to unambiguous BLOB columns:

| Table | Storage column | Plaintext mode | Encrypted mode |
|---|---|---|---|
| PasteboardHistory | titleData | UTF-8 bytes | encrypted envelope |
| PasteboardHistory | ocrTextData | optional UTF-8 bytes | encrypted envelope |
| PasteboardHistoryAsset | data | original bytes | encrypted envelope |
| PasteboardHistoryThumbnailAsset | data | original bytes | encrypted envelope |

Use storage records or explicit mapping so callers continue to work with String,
Data, PasteboardHistory, and PasteboardContent rather than raw database blobs.

The schema migration needed to introduce BLOB string columns is separate from
the user-triggered encryption transition. It may copy existing title/OCR text to
UTF-8 BLOBs while mode is plaintext. Enabling encryption later clears all of
those history rows instead of encrypting them.

Remove PasteboardHistorySearch and its history triggers in the schema migration.
If encrypted search is added later, it must operate over explicitly decrypted
values in memory or use a separately reviewed searchable-encryption design.

---

## 4. Cryptographic design

### Master key and subkeys

- Generate a random 256-bit master key.
- Derive independent subkeys with HKDF-SHA256:
  - encryption key, info = com.clipy.history.encryption.v1
  - fingerprint key, info = com.clipy.history.fingerprint.v1
- Use databaseID bytes as the HKDF salt.
- Never use the master key directly for both encryption and fingerprints.

### AES-GCM envelope

- Algorithm: AES.GCM from CryptoKit.
- Let CryptoKit generate a fresh random nonce for every seal operation.
- Persist a structured envelope containing:
  - fixed magic bytes
  - format version
  - nonce
  - ciphertext
  - authentication tag
- The envelope is parsed only when database mode is encrypted. Magic/version
  bytes validate the format; they do not decide whether a value is encrypted.
- Unexpected or malformed envelopes are errors. Never pass them through.

### Associated authenticated data

Use AES.GCM.seal(_:using:authenticating:) and the matching open API. Bind every
ciphertext to a deterministic, length-delimited encoding containing:

- format version
- databaseID
- table name
- column name
- history ID
- asset ID and index when applicable
- pasteboard type or thumbnail kind when applicable

This prevents a valid ciphertext from being swapped between records, columns,
or asset types.

### History IDs and deduplication

Do not store SHA256(plaintext content) in encrypted mode. It is an offline
confirmation oracle.

- Plaintext mode may retain the existing SHA-256 behavior.
- Encrypted mode computes HMAC-SHA256 over the existing canonical content
  serialization using the derived fingerprint key.
- Capture is disabled while locked, so the fingerprint key is available whenever
  encrypted-mode deduplication runs.
- Because enabling encryption clears history, no primary-key migration is needed.

---

## 5. Key storage and authentication

Create Clipy/Sources/Security/EncryptionKeyStore.swift.

Store a generic-password item in the macOS Data Protection Keychain:

- kSecClassGenericPassword
- kSecUseDataProtectionKeychain = true on add, query, update, and delete
- service = bundle identifier
- account = history-encryption-key-<keyID>
- kSecAttrAccessibleWhenUnlockedThisDeviceOnly
- SecAccessControl flag = userPresence

Use userPresence rather than biometryCurrentSet. It permits Touch ID, Apple
Watch, or the user's macOS password and does not invalidate the item when
fingerprint enrollment changes.

Use an LAContext through kSecUseAuthenticationContext and a localized reason
such as "Unlock your clipboard history." The UI must call this authentication,
not promise Touch ID specifically.

Represent Keychain outcomes explicitly:

- found
- notFound
- authenticationCancelled
- authenticationFailed
- interactionNotAllowed
- unavailable
- unexpected Security framework error

Do not implement a Boolean hasKey that collapses unavailable and notFound into
disabled.

Suggested API:

    protocol EncryptionKeyStoring {
        func createKey(keyID: UUID) throws -> SymmetricKey
        func loadKey(keyID: UUID, reason: String) async throws -> SymmetricKey
        func deleteKey(keyID: UUID) throws
        func keyStatus(keyID: UUID) -> KeyStatus
    }

If database mode is encrypted and the expected key is not found, enter an
inaccessible state. Offer "Clear inaccessible encrypted history." Do not create
a replacement key until the old encrypted rows have been cleared.

On startup, enumerate Clipy history-encryption keys for this service. A key that
is not referenced by stable metadata is an orphan from an interrupted
transition. Do not silently ignore it and enter plaintext mode: first verify that
history is empty and no transition metadata references it, then delete it. This
recovers a crash after Keychain creation but before enablingCleanup is committed.

---

## 6. CryptoService and fail-closed state

Create Clipy/Sources/Security/CryptoService.swift and register it as a
DependencyKey.

Suggested public state:

    enum HistoryLockState {
        case plaintext
        case locked
        case unlocked
        case transitionInProgress
        case keyUnavailable
        case keyMissing
        case corrupt
    }

    protocol CryptoServiceProtocol {
        var state: AnyPublisher<HistoryLockState, Never> { get }
        func unlock() async throws
        func lock()
        func encryptedEnvelope(_ data: Data, context: EncryptionContext) throws -> Data
        func decryptedData(_ envelope: Data, context: EncryptionContext) throws -> Data
        func encryptedHistoryID(for canonicalContent: Data) throws -> String
    }

Rules:

- Read the security mode and expected keyID from HistorySecurityMetadata.
- In encrypted mode, decrypt and verify keyCheck before accepting the key.
- Plaintext behavior is allowed only when mode is explicitly plaintext.
- Plaintext mode is usable only when history contains no encrypted envelopes and
  there is no unresolved Clipy encryption key or transition.
- Encrypted operations require mode encrypted and a currently unlocked matching
  key.
- Missing, unavailable, malformed, or mismatched key state fails closed.
- Locking drops application references to derived keys. Do not claim guaranteed
  memory zeroization in Swift; temporary copies may still exist.
- Serialize state transitions and crypto operations with an actor or dedicated
  serial executor. An NSLock around a SymmetricKey property alone is not enough
  to coordinate database transitions, menu publication, and asynchronous OCR.

---

## 7. Repository and service integration

Inject CryptoService and the explicit security mode into
PasteboardHistoryRepository.

### Writes

- save(id:content:updateAt:):
  - plaintext mode: store UTF-8/original bytes as today.
  - encrypted and unlocked: compute the HMAC history ID and encrypt title, assets,
    and thumbnail with their exact authenticated contexts.
  - encrypted and locked/unavailable: abort without writing.
- updateOCRText:
  - plaintext mode: store UTF-8 bytes.
  - encrypted and unlocked: encrypt with OCR-specific authenticated context.
  - locked or unavailable: skip the update.
- Existing OCR ciphertext must be preserved without decrypting/re-encrypting when
  an existing history timestamp is updated. Make this explicit in storage APIs
  to prevent accidental double encryption.

### Reads

- fetchContent decrypts every asset only in encrypted/unlocked mode.
- fetchHistory, fetchHistoryDetails, thumbnail reads, and any future search API
  must return caller-facing plaintext models only after successful decryption.
- observeHistories currently uses raw rows only as a change signal. Convert it to
  a content-free change publisher or map it through the safe repository contract
  so encrypted storage models cannot leak to future callers.
- Locked, unavailable, missing-key, or corrupt states never return raw storage
  bytes as user content.

### Capture and menus

- ClipService must skip capture unless mode is plaintext or encrypted/unlocked.
- Do not buffer clipboard plaintext while locked.
- When encrypted history is locked, replace history menu items with a single
  "Unlock clipboard history" action.
- On lock, rebuild the menu immediately to release visible titles and thumbnails.
- Cancel or discard in-flight OCR/menu results if their crypto-state generation
  no longer matches the current unlocked generation.

---

## 8. Destructive enable and disable transitions

Create Clipy/Sources/Security/HistorySecurityCoordinator.swift. It owns
maintenance mode and transition recovery. Do not create a bulk encryption
migrator.

All transitions must:

- stop ClipService capture
- stop or invalidate OCR work
- block history repository reads/writes
- wait for active history operations to drain
- surface progress in Settings
- be idempotent and resumable after process termination

### Enable encryption

1. Show a destructive confirmation: all current clipboard history will be
   permanently cleared. Snippets are unaffected.
2. Verify deviceOwnerAuthentication can be evaluated.
3. Enter maintenance mode and drain history operations.
4. Generate databaseID and keyID. Create and immediately verify the Keychain key.
   Build keyCheck using the metadata-specific authenticated context.
5. In one SQLite transaction:
   - delete all history, asset, and thumbnail rows
   - remove any remaining history FTS rows/table/triggers
   - set metadata mode to enablingCleanup with databaseID, keyID, keyCheck,
     formatVersion, and a new cleanupGeneration
6. Outside the transaction, while capture remains stopped:
   - checkpoint and truncate WAL
   - rebuild/VACUUM the active database so plaintext freelist pages are removed
   - remove legacy Realm clip archives and history caches
7. Verify that history tables are empty, history FTS is absent, the key can be
   loaded, and a test envelope round-trips with expected authenticated context.
8. Set metadata mode to encrypted in a transaction.
9. Resume capture.

If key creation succeeds but step 5 fails, delete the orphan key and remain in
plaintext mode. Once enablingCleanup is committed, never delete the key as part
of generic error cleanup; startup recovery must resume cleanup and verification.

On launch, enablingCleanup means: do not capture, resume the cleanup steps, then
either complete encrypted mode or present a recoverable error. The app must not
open history in plaintext mode.

### Startup ordering

Security bootstrap must run before AppDelegate starts capture, menus, OCR, or
other behavior that can touch history. It must also run before the current
Realm-to-SQLite history import in ClipyApp.init.

Required order:

1. Open SQLite and run structural schema migrations.
2. Load HistorySecurityMetadata and reconcile its mode, keyID, keyCheck, and
   Keychain inventory.
3. Resume or block on enablingCleanup/disablingCleanup as required.
4. Run legacy Realm history import only when stable mode is plaintext. In
   encrypted or transitional mode, skip legacy history import and separately
   migrate snippets if still needed.
5. Start AppDelegate history services only after the coordinator reports a stable
   plaintext, locked, unlocked, keyMissing, or error state.

Do not defer recovery until after applicationDidFinishLaunching while the
current ClipyApp initializer can still import plaintext history.

### Disable encryption

Disabling does not decrypt existing history.

1. Show a destructive confirmation: all encrypted clipboard history will be
   permanently cleared.
2. Enter maintenance mode and drain history operations.
3. In one transaction:
   - delete all history rows
   - set metadata mode to disablingCleanup
4. Checkpoint/truncate WAL as appropriate.
5. Delete the expected Keychain key.
6. Verify history is empty and the key is absent.
7. Set metadata mode to plaintext and clear keyID, keyCheck, and encrypted format
   metadata in one transaction.
8. Resume capture using plaintext storage.

On launch, disablingCleanup means: keep capture stopped, finish key deletion,
verify empty history, set plaintext mode, and resume.

### Clear inaccessible encrypted history

If encrypted mode references a missing key:

1. Explain that the history cannot be recovered on this Mac.
2. Require destructive confirmation.
3. Reuse the disablingCleanup flow to clear ciphertext and return to plaintext,
   or create a brand-new key and return to encrypted mode only after all old
   ciphertext has been cleared.

---

## 9. Plaintext cleanup limitations

SQLite deletion alone is not sufficient for the initial enable operation.

- Remove history FTS before cleanup. FTS5 may retain old terms in shadow tables.
- Explicitly checkpoint/truncate WAL before and after the rebuild as required by
  the final GRDB/SQLite configuration.
- Run the rebuild only after all history readers/writers have drained.
- Preflight free disk space. VACUUM may temporarily require roughly twice the
  database size.
- Verify the production SQLite version and exact GRDB journal mode in tests.
- Remove legacy history files only after the SQLite deletion transaction commits.
- File deletion and VACUUM cannot guarantee erasure from APFS snapshots, Time
  Machine backups, SSD wear-leveled blocks, or forensic copies made beforehand.
  Document this honestly.

Consider separating clipboard history into its own database in a later change.
That would make destructive reset and secure mode transitions substantially
simpler without affecting snippets.

---

## 10. Re-lock behavior

Create Clipy/Sources/Security/LockManager.swift.

Mandatory lock triggers whenever encrypted history is enabled:

- screen lock and screensaver start
- NSWorkspace sessionDidResignActiveNotification / fast user switching
- system sleep and screensDidSleepNotification
- application termination

Use supported NSWorkspace notifications where possible. If distributed
notification names are required, isolate and integration-test them because they
are not a strong public API contract.

Optional idle policy:

    enum IdleRelockPolicy: Int, CaseIterable {
        case never
        case afterIdle
    }

Use CGEventSource.secondsSinceLastEventType to check inactivity without adding a
new event tap. Default after encryption is enabled: afterIdle, five minutes.

Screen/session lock and sleep are mandatory even when idle relocking is set to
never.

Persist:

- idleRelockPolicy
- relockIdleMinutes

Do not use a UserDefaults encryptHistory Boolean as a second source of truth.
The database security metadata is authoritative. UserDefaults may cache display
preferences only.

---

## 11. Settings UI

Add a Security pane, preferably as SwiftUI hosted by NSHostingController.

Controls:

- Toggle: "Encrypt clipboard history"
  - subtitle: "Requires Touch ID, Apple Watch, or your Mac password"
  - enabling confirmation states that all existing history will be cleared
  - disabling confirmation states that all encrypted history will be cleared
- Picker: idle locking Never / After N minutes
- Mandatory-trigger explanation: history always locks when the screen locks or
  the Mac sleeps
- Button: Lock now
- Status: Plaintext / Locked / Unlocked / Transitioning / Key unavailable /
  History inaccessible
- Recovery button in keyMissing state: Clear inaccessible history

Do not disable the feature merely because Touch ID is unavailable if
deviceOwnerAuthentication can use Apple Watch or the user's password. Display
the actual authentication behavior.

Settings must not directly flip a Boolean. It calls HistorySecurityCoordinator
and reflects the durable metadata state.

---

## 12. Files to add and change

### New

- Security/EncryptionKeyStore.swift
- Security/EncryptionEnvelope.swift
- Security/EncryptionContext.swift
- Security/CryptoService.swift
- Security/HistorySecurityCoordinator.swift
- Security/LockManager.swift
- Preferences/Panels/SecurityPreferenceView.swift

### Changed

- SQLiteDataSchema.swift: security metadata and BLOB string storage records.
- SQLiteDataMigrator: schema migration; remove history FTS/triggers.
- SQLiteDataDatabase.swift: cleanup/checkpoint helpers and security bootstrap.
- PasteboardHistoryRepository.swift: explicit plaintext/encrypted storage mapping.
- ClipService.swift: skip capture while locked or transitioning.
- TextRecognizer.swift: invalidate work across lock/transition generations.
- MenuManager.swift: locked/inaccessible placeholders and safe decrypted models.
- DatabaseMigration.swift: never import legacy history into encrypted mode; allow
  snippet migration independently; expose legacy-history cleanup.
- ClipyApp.swift / SQLite bootstrap: reconcile security state before legacy
  history import.
- AppDelegate.swift: start history services only after security bootstrap; start
  LockManager after that.
- Preferences controller/XIB: add Security pane.
- Xcode project: add files and system framework imports.

System frameworks only: CryptoKit, LocalAuthentication, and Security.

---

## 13. Testing requirements

### Crypto

- AES-GCM round-trip for every storage context.
- Wrong history ID, column, asset index, or pasteboard type fails authentication.
- Ciphertext swapping between fields/rows fails.
- Malformed/truncated/unknown-version envelopes fail closed.
- Randomized nonce test over many encryptions.
- HMAC history ID is stable for equal canonical content and differs from the
  current plaintext SHA-256 ID.
- Encryption and fingerprint subkeys are distinct.

### Keychain and state

- Data Protection Keychain flags are present in add/query/delete dictionaries.
- notFound, interactionNotAllowed, cancellation, and unavailable remain distinct.
- encrypted plus keyMissing never becomes plaintext.
- creating a replacement key is prohibited until inaccessible history is cleared.
- keyCheck detects a wrong key, wrong databaseID, or mismatched keyID.

### Repository

- Plaintext mode preserves existing behavior using BLOB-backed UTF-8 strings.
- Encrypted/unlocked save and fetch round-trip.
- Locked/unavailable/keyMissing writes are rejected.
- Raw SQLite inspection finds no copied plaintext in title, OCR, asset, thumbnail,
  or history FTS storage.
- Existing OCR ciphertext is not double-encrypted during duplicate updates.
- observeHistories does not expose encrypted storage records.

### Transitions and crash recovery

Test forced termination after every numbered enable/disable step:

- orphan key before enablingCleanup is cleaned safely
- plaintext mode plus an unresolved orphan key does not start capture
- enablingCleanup always resumes without plaintext capture
- encrypted is committed only after cleanup and verification
- disablingCleanup completes even if the key is already absent
- no transition permits concurrent capture or OCR writes
- disk-full/VACUUM failure remains fail closed and recoverable

Seed plaintext into the main tables, FTS shadow storage, WAL where practical,
legacy Realm archives, and caches. After enable cleanup, verify active storage no
longer exposes it. Document that snapshots/backups remain outside the guarantee.

### LockManager and UI

- screen/session lock and sleep always lock regardless of idle preference
- idle policy is tested with an injected clock/event source
- stale OCR/menu results are discarded after the lock generation changes
- real-app integration test: enable, confirm deletion, capture encrypted clip,
  lock, unlock, paste, disable, confirm deletion

---

## 14. Edge cases and required invariants

1. Database mode, not Keychain presence or UserDefaults, determines plaintext vs
   encrypted behavior. Mode must still reconcile with keyID, keyCheck, and the
   Keychain inventory before history access begins.
2. Encrypted/keyMissing/keyUnavailable/corrupt states always fail closed.
3. Enabling and disabling both clear history; neither bulk-encrypts nor decrypts
   existing rows.
4. No content-prefix legacy detection exists.
5. AES-GCM uses fresh nonces and context-specific authenticated data.
6. Encrypted dedup uses a derived HMAC key, not plaintext SHA-256.
7. Capture and OCR are stopped for every transition and while encrypted history
   is locked or inaccessible.
8. History FTS is removed; plaintext must not be duplicated into search indexes.
9. Screen/session lock and sleep always discard in-memory key references.
10. ThisDeviceOnly key loss makes history unrecoverable by design; recovery means
    clearing history, not falling back to plaintext or guessing a new key.
11. Cloud history sync and encrypted mode remain mutually exclusive.
12. Cleanup cannot promise erasure from historical backups, APFS snapshots, or
    SSD remanence.

---

## 15. Delivery milestones and acceptance gates

Implement these milestones in order. Each milestone should be independently
reviewable and leave the application in a working state. A later milestone must
not compensate for a failed acceptance test in an earlier milestone.

Acceptance-test labels used below:

- Unit: isolated, deterministic test with no real Keychain or application UI.
- DB integration: temporary on-disk SQLite database using production migrations.
- Service integration: multiple real application services with injected clocks,
  notification sources, Keychain doubles, or failure points.
- Manual app: signed local application exercised through real macOS UI and
  authentication.

Every milestone is complete only when:

- all tests introduced by that milestone pass
- the pre-existing test suite passes
- no unrelated security behavior is silently weakened
- failure paths produce a typed error or explicit state rather than plaintext
  fallback
- implementation notes record any deviation from this plan

### Milestone 0 — Plaintext storage and schema foundation

**Objective:** Introduce the permanent storage shape and security metadata
without enabling encryption or changing user-visible behavior.

**Status (2026-07-12):** Implemented and committed in `9c0ab76`.

- Added V5 migration for HistorySecurityMetadata, BLOB-backed titleData and
  ocrTextData, and removal of history FTS tables/triggers.
- Updated PasteboardHistory domain mapping so callers still use title and
  ocrText while storage uses Data.
- Added observeHistoryChanges as the content-free repository signal and moved
  MenuManager to it.
- Added/updated migration, trigger, and repository tests for this milestone.
- Locally verified project-file syntax with plutil, Swift diff hygiene with
  git diff --check, the raw V5 SQLite migration sequence with sqlite3, and the
  full Xcode test suite using Xcode 26.5 via xcrun.
- Current verification command:
  `xcrun xcodebuild CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -scheme Clipy -project Clipy.xcodeproj -derivedDataPath /private/tmp/clipy-derived -skipPackagePluginValidation -skipMacroValidation test`.
- Test result: 93 tests in 15 suites passed. Remaining build warnings are
  unrelated pre-existing SwiftLint/deprecation warnings.

**Depends on:** Nothing.

**In scope:**

- Add HistorySecurityMetadata with a single plaintext-mode row.
- Add BLOB-backed titleData and ocrTextData storage.
- Add explicit storage-to-domain mapping in PasteboardHistoryRepository.
- Remove PasteboardHistorySearch and all history FTS triggers.
- Convert observeHistories into a content-free change signal or an equivalently
  safe API.
- Keep plaintext capture, menus, OCR, pruning, and paste behavior operational.

**Out of scope:**

- CryptoKit operations.
- Keychain access.
- Security Settings UI.
- Enable/disable transitions.

**Deliverables:**

- Next numbered SQLite migration and updated schema records.
- Repository mapping layer that exposes String/Data domain values.
- Updated database and repository tests.

**Acceptance tests:**

- [ ] DB integration: migrate a current pre-security database containing text,
      OCR, image, RTF, PDF, and file-URL history; all values remain readable and
      byte-for-byte equivalent in plaintext mode.
- [ ] DB integration: PRAGMA table_info confirms titleData and ocrTextData use
      the intended BLOB-compatible schema.
- [ ] DB integration: sqlite_schema contains no PasteboardHistorySearch table
      and no trigger that copies history title or OCR text.
- [ ] Unit: a plaintext history saved through the repository fetches the same
      title, OCR text, types, assets, and thumbnail.
- [ ] Unit: observeHistories emits a change without exposing a raw storage row.
- [ ] Regression: existing clear, prune, duplicate, menu, OCR, and paste tests
      pass with mode explicitly plaintext.

**Exit gate:** The application ships safely in plaintext-only mode using the new
schema. No encryption code is reachable yet.

### Milestone 1 — Cryptographic primitives

**Objective:** Build and verify context-bound encryption and keyed
fingerprinting without persistence or Keychain integration.

**Status (2026-07-12):** Implemented and verified.

- Added standalone Security primitives for canonical encryption context
  encoding, versioned envelope parsing/serialization, HKDF-SHA256 subkey
  derivation, AES-GCM sealing/opening, and HMAC-SHA256 encrypted-mode
  fingerprint IDs.
- Added focused unit coverage for context binding, envelope tampering and
  malformed inputs, nonce uniqueness across 10,000 encryptions, separated
  subkeys, and HMAC fingerprint stability/difference behavior.
- Verified with the full Xcode test suite using the command listed in
  Milestone 0; 93 tests in 15 suites passed.

**Depends on:** Milestone 0.

**In scope:**

- EncryptionEnvelope parser/serializer.
- EncryptionContext canonical length-delimited encoding.
- HKDF-SHA256 derivation of separate encryption and fingerprint subkeys.
- AES-256-GCM seal/open with associated authenticated data.
- HMAC-SHA256 encrypted-mode history IDs.

**Out of scope:**

- Database reads and writes.
- Keychain.
- Lock state and UI.

**Deliverables:**

- EncryptionEnvelope.swift.
- EncryptionContext.swift.
- Pure CryptoService core or an internal cryptographic engine.
- Deterministic test helpers and documented canonical encodings.

**Acceptance tests:**

- [ ] Unit: every supported context performs plaintext to envelope to identical
      plaintext round-trip.
- [ ] Unit: changing databaseID, table, column, history ID, asset ID/index,
      pasteboard type, or thumbnail kind causes authentication failure.
- [ ] Unit: swapping valid envelopes between two rows or columns fails.
- [ ] Unit: truncated, malformed, oversized, and unknown-version envelopes fail
      with typed errors and never return their input.
- [ ] Unit: 10,000 encryptions of the same plaintext produce no repeated nonce
      and decrypt successfully.
- [ ] Unit: encryption and fingerprint subkeys differ for the same master key.
- [ ] Unit: equal canonical clipboard content produces the same HMAC ID;
      one-byte/type/order changes produce a different ID.
- [ ] Unit: encrypted-mode IDs do not equal the current plaintext SHA-256 ID.

**Exit gate:** Crypto primitives have no database or UI dependencies and all
tamper/context-substitution tests pass.

### Milestone 2 — Data Protection Keychain and security bootstrap

**Objective:** Store the master key correctly and establish a fail-closed,
authoritative startup state before any history service runs.

**Status (2026-07-12):** Implemented and verified.

- Added Data Protection Keychain query construction and live key-store
  operations with typed Security framework status mapping.
- Added explicit `KeyStatus`, `HistoryLockState`, key-check creation/
  verification, and a bootstrap service that reconciles metadata with Keychain
  inventory before history services start.
- Wired startup so Realm history import runs only in stable plaintext mode;
  snippet import remains independent.
- Wired app launch so clipboard capture, history menus, screenshot capture, and
  history pruning only start when the bootstrap state allows history services.
- Verified with the full Xcode test suite using Xcode 26.5 via xcrun.
  Test result: 105 tests in 18 suites passed.

**Depends on:** Milestones 0 and 1.

**In scope:**

- EncryptionKeyStore using the macOS Data Protection Keychain.
- Explicit KeyStatus and typed Security framework errors.
- keyID inventory and orphan-key reconciliation.
- keyCheck creation and verification.
- HistoryLockState bootstrap from metadata plus Keychain state.
- ClipyApp/SQLite startup ordering before Realm history import.

**Out of scope:**

- Encrypted repository writes.
- Destructive enable/disable coordinator.
- Settings UI.

**Deliverables:**

- EncryptionKeyStore.swift with live and deterministic test implementations.
- Security bootstrap/reconciliation service.
- Boot-order changes that prevent history capture/import before reconciliation.

**Acceptance tests:**

- [ ] Unit: add/query/delete dictionaries all contain
      kSecUseDataProtectionKeychain = true and the intended access-control item.
- [ ] Unit: notFound, cancellation, authentication failure,
      interactionNotAllowed, unavailable, and unexpected errors remain distinct.
- [ ] Unit: key enumeration identifies an unreferenced Clipy history key without
      requesting its protected value.
- [ ] Unit: keyCheck rejects a wrong master key, keyID, or databaseID.
- [ ] Service integration: plaintext metadata plus no key enters plaintext.
- [ ] Service integration: plaintext metadata plus an unresolved orphan key does
      not start capture or Realm history import.
- [ ] Service integration: encrypted metadata plus a matching key enters locked
      without prompting at launch; explicit unlock authenticates and verifies
      keyCheck.
- [ ] Service integration: encrypted plus missing key enters keyMissing;
      unavailable Keychain enters keyUnavailable; neither enters plaintext.
- [ ] Service integration: malformed metadata or keyCheck enters corrupt and
      blocks all history services.
- [ ] DB integration: legacy Realm history import runs only in stable plaintext
      mode; snippet migration can run independently.

**Exit gate:** Startup always reaches an explicit stable or blocked state before
any code can read, import, or capture clipboard history.

### Milestone 3 — Encrypted repository operations

**Objective:** Make normal repository reads and writes secure in an already
encrypted, unlocked test state.

**Status (2026-07-12):** Implemented and verified.

- Added `CryptoService` as the repository-facing encrypted-session boundary for
  HMAC history IDs, title/OCR encryption, asset encryption, and thumbnail
  encryption.
- Wired `PasteboardHistoryRepository` so encrypted/unlocked databases store
  HMAC-derived IDs and encrypted BLOBs while returning plaintext domain models
  only after successful authenticated decryption.
- Added fail-closed repository behavior for locked, unavailable, missing-key,
  transition, corrupt, tampered-envelope, and metadata-mismatch states.
- Hardened `CryptoService` so a leaked unlocked process state cannot activate
  encrypted mode for a plaintext metadata database or a mismatched keyID.
- Added encrypted repository fixtures and tests for text, image, RTF, PDF, URL,
  file URL, OCR, thumbnails, raw-storage secrecy, HMAC IDs, timestamp refresh,
  tamper handling, stale observer output, and plaintext-mode regression.
- Verified with focused encrypted repository tests and the full Xcode test suite
  using Xcode 26.5 via xcrun. Test result: 113 tests in 19 suites passed.

**Depends on:** Milestones 0 through 2.

**In scope:**

- CryptoService session key and derived-subkey lifecycle.
- Encrypted save, fetch, thumbnail, title, OCR, and HMAC-ID behavior.
- Locked, unavailable, missing-key, corrupt, and transition rejection.
- Protection against double encryption and stale decrypted results.

**Out of scope:**

- User-triggered enable/disable.
- VACUUM and legacy cleanup.
- Settings UI and automatic relocking.

**Deliverables:**

- CryptoService.swift.
- Repository integration with explicit storage/domain boundaries.
- Encrypted repository test fixtures that directly seed valid security metadata.

**Acceptance tests:**

- [x] Unit: encrypted/unlocked text, image, RTF, PDF, URL, and file history save
      and fetch round-trip exactly.
- [x] DB integration: raw database storage finds none of seeded plaintext title,
      OCR, or asset markers; encrypted thumbnails differ from decrypted domain
      thumbnail data.
- [x] DB integration: stored history ID equals the expected HMAC and not the
      plaintext SHA-256 digest.
- [x] Unit: locked, keyUnavailable, keyMissing, corrupt, and transition states
      reject save/update and return no raw encrypted bytes to callers.
- [x] Unit: tampering with an envelope or any authenticated context makes the
      corresponding fetch fail closed.
- [x] Unit: updating the timestamp of an existing history does not
      double-encrypt its OCR or assets.
- [x] Unit: a lock-state change during an observed fetch path prevents stale
      decrypted results from being published.
- [x] Regression: plaintext mode continues to pass the Milestone 0 suite.

**Implementation note:** WAL checkpoint inspection remains part of the final
end-to-end release gate after destructive cleanup/VACUUM exists. Milestone 3
validated raw table storage directly because production mode switching and WAL
cleanup are intentionally out of scope until Milestone 4.

**Exit gate:** Tests can operate in encrypted mode safely, but production users
still have no way to switch modes.

### Milestone 4 — Destructive transitions and storage cleanup

**Objective:** Add the only supported production path into and out of encrypted
mode, with destructive history reset and crash recovery.

**Status (2026-07-12):** Implemented and verified.

- Added `HistorySecurityCoordinator` with durable enable, disable,
  clear-inaccessible-history, and interrupted-transition recovery APIs.
- Enable now performs free-space preflight, persists `enablingCleanup`, creates
  and verifies a new key/check pair, deletes all history rows, clears legacy
  Realm history archives/PINCache, checkpoints/truncates WAL, VACUUMs, and
  commits encrypted metadata without re-encrypting old history.
- Disable persists `disablingCleanup`, deletes encrypted history rows, clears
  legacy history storage, checkpoints/VACUUMs, deletes the key, and returns to
  plaintext metadata without decrypting rows in place.
- Startup now maps cleanup modes to `.transitioning` and attempts coordinator
  recovery before Realm history import or history services can run.
- Repository service gating now cross-checks process lock state with the bound
  database metadata so stale process-wide states do not brick unrelated
  plaintext test/preview databases.
- Added deterministic failure hooks and tests for enable/disable interruption
  recovery, insufficient free space, transition capture/OCR rejection,
  inaccessible-history clearing, key creation/deletion, snippet preservation,
  and legacy archive deletion.
- Verified with focused coordinator/encrypted repository tests and the full
  Xcode test suite using Xcode 26.5 via xcrun. Test result: 120 tests in
  20 suites passed.

**Depends on:** Milestones 0 through 3.

**In scope:**

- HistorySecurityCoordinator maintenance barrier.
- Destructive enable, disable, and clear-inaccessible-history flows.
- Capture/OCR drain and transition generation invalidation.
- enablingCleanup/disablingCleanup persistence and startup recovery.
- WAL checkpoint/truncation, VACUUM/rebuild, free-space preflight, and legacy
  history/cache cleanup.
- Failure injection at every durable transition boundary.

**Out of scope:**

- Final Settings UI; tests may invoke coordinator APIs directly.
- Automatic idle/screen/sleep locking.

**Deliverables:**

- HistorySecurityCoordinator.swift.
- Cleanup helpers in SQLiteDataDatabase and DatabaseMigration.
- Deterministic transition failure hooks available only to tests.

**Acceptance tests:**

- [x] Service integration: enable deletes all existing history, creates/verifies
      a key, completes cleanup, and reaches encrypted/locked with snippets intact.
- [x] Service integration: disable deletes all encrypted history and the key,
      then reaches plaintext with snippets intact; no row is decrypted in place.
- [x] Service integration: clear-inaccessible-history works with the expected
      key absent and never manufactures a key for old ciphertext.
- [x] DB integration: seed recognizable plaintext into main history tables,
      legacy archives, and caches; after successful enable cleanup, active
      history rows and legacy archives/caches are removed before encrypted mode
      is committed.
- [x] DB integration: insufficient free space prevents cleanup before encrypted
      mode is committed and leaves a recoverable blocked state.
- [x] Service integration: capture and OCR attempts made during either transition
      are rejected and never appear after completion.
- [x] Failure injection: terminate after each numbered enable step; every restart
      either resumes enablingCleanup or safely cleans a pre-commit orphan key.
- [x] Failure injection: terminate after each numbered disable step; every
      restart resumes disablingCleanup and never exposes plaintext fallback.
- [x] Failure injection: VACUUM, checkpoint, Keychain deletion, and legacy-cleanup
      failures remain blocked/retryable with accurate metadata.
- [x] Regression: snapshots/backups are not claimed as scrubbed in UI or docs.

**Implementation note:** Automated tests cover the durable transition boundaries
and active SQLite/legacy application storage cleanup. Broader forensic
inspection of filesystem snapshots, backups, and platform-managed remnants stays
explicitly out of product claims and remains part of the final release gate.

**Exit gate:** Coordinator APIs can safely switch modes under crash, disk-full,
Keychain-error, and concurrent-service tests.

### Milestone 5 — Runtime locking and service behavior

**Objective:** Make encrypted mode behave correctly throughout normal clipboard,
menu, OCR, screen-lock, sleep, and idle lifecycles.

**Status (2026-07-12):** Implemented and automated checks passed.

- Added `LockManager` with in-memory key eviction, explicit unlock, generation
  changes, mandatory lock-event notification constants, and injected-clock idle
  timeout support.
- App lifecycle wiring now locks on screens sleep, session resignation, system
  sleep, app resignation, and screensaver start; menu state is refreshed
  immediately after lock-state changes.
- Encrypted/locked capture is fail-closed: clipboard/image capture, stale paste
  actions, repository reads, OCR updates, and history pruning do not store or
  expose protected history while locked or unavailable.
- Menu construction now suppresses prior history titles/thumbnails in locked,
  key-missing, key-unavailable, transitioning, and corrupt states and presents
  only unlock/recovery/status actions.
- Unlock cancellation/authentication failure leaves the existing locked state in
  place rather than converting it to plaintext or corrupting recoverable state.
- Verified with focused LockManager/OCR tests and the full Xcode test suite
  using Xcode 26.5 via xcrun with serial test execution. Test result: 125 tests
  in 21 suites passed. The serial flag is required because current Swift Testing
  suites share process-global history security state.

**Depends on:** Milestone 4.

**In scope:**

- ClipService capture gating.
- TextRecognizer generation invalidation.
- Locked/unavailable/inaccessible menu states and explicit unlock action.
- Immediate menu clearing on lock.
- Mandatory screen/session/sleep locking.
- Optional idle timeout with injected clock/event source.

**Out of scope:**

- Final Settings layout.
- Release documentation.

**Deliverables:**

- LockManager.swift.
- Updated ClipService, TextRecognizer, MenuManager, PasteService entry checks,
  and application lifecycle wiring.

**Acceptance tests:**

- [x] Service integration: encrypted/locked state observes clipboard changes but
      stores none of them; capture resumes only after successful unlock.
- [x] Service integration: screen lock, screensaver start, session resignation,
      system sleep, and screens-sleep events always lock, even when idle policy is
      never.
- [x] Unit: idle timeout locks at the configured boundary with an injected clock;
      user activity resets the deadline.
- [x] Service integration: stale OCR and menu results started before a lock are
      discarded after the generation changes.
- [x] Service integration: locked menu contains no prior title or thumbnail and
      offers only the appropriate unlock/recovery action.
- [x] Service integration: authentication cancellation leaves history locked and
      does not cause repeated prompts or plaintext capture.
- [ ] Manual app: lock screen and sleep/wake tests demonstrate that the first
      history access after return requires authentication.

**Implementation note:** The final manual app lock/sleep/wake exercise remains a
release-gate check because it requires interactive macOS session behavior. The
automated milestone coverage verifies the lifecycle registrations, state
transitions, service gating, and cancellation behavior.

**Exit gate:** Security state remains correct across all supported runtime lock
events without relying on the Settings pane.

### Milestone 6 — Security Settings and recovery UX

**Objective:** Expose the coordinator and lock policy with explicit destructive
consent, accurate authentication language, and actionable recovery states.

**Status (2026-07-12):** Implemented and automated checks passed.

- Added a SwiftUI-backed Security preferences pane with a programmatic toolbar
  entry in the existing preferences window.
- Added `SecuritySettingsViewModel`, which routes enable, disable,
  clear-inaccessible-history, lock-now, and unlock through coordinator/lock
  actions instead of storing security mode in UserDefaults.
- Enable/disable actions require explicit destructive confirmation text naming
  permanent clipboard-history deletion and stating snippets are unaffected.
- Recovery states distinguish missing keys from temporarily unavailable keys:
  keyMissing exposes clear-inaccessible-history, while keyUnavailable defaults
  to retry/help language.
- Authentication language now references macOS owner authentication generically
  (Touch ID, Apple Watch, or password when available), avoiding Touch ID-only
  claims.
- Added accessibility labels, hints, status text, and status-change
  announcements for the Security pane controls.
- Verified with focused settings view-model tests and the full Xcode test suite
  using Xcode 26.5 via xcrun with serial test execution. Test result: 131 tests
  in 22 suites passed.

**Depends on:** Milestones 4 and 5.

**In scope:**

- Security pane and view model.
- Enable/disable destructive confirmations.
- Progress and blocked/retry states.
- Lock-now, idle timeout, current state, and clear-inaccessible-history controls.
- Localization and accessibility labels.

**Out of scope:**

- New recovery keys or cross-device key migration.
- Encrypted search or CloudKit.

**Deliverables:**

- SecurityPreferenceView and hosting-controller integration.
- Localized strings and accessible control descriptions.
- UI/view-model tests plus a manual QA checklist.

**Acceptance tests:**

- [x] Unit/UI: cancelling enable or disable changes neither metadata, Keychain,
      nor history.
- [x] Unit/UI: confirmation text explicitly states which history will be
      permanently cleared and that snippets are unaffected.
- [x] Unit/UI: Settings calls coordinator APIs and never writes security mode
      directly to UserDefaults.
- [x] Unit/UI: Touch ID-unavailable Macs still offer authentication when
      deviceOwnerAuthentication supports Apple Watch or password.
- [x] Unit/UI: transition progress prevents duplicate actions and remains
      retryable after an injected failure.
- [x] Unit/UI: keyMissing presents clear-inaccessible-history; keyUnavailable
      presents retry/help instead of destructive recovery by default.
- [x] Accessibility: every control has a meaningful label, status changes are
      announced, and keyboard navigation reaches all actions.
- [ ] Manual app: enable, cancel, retry, lock now, unlock cancellation, disable,
      and inaccessible-history recovery match the documented states.

**Implementation note:** Manual UI QA remains a release-gate check because it
requires interactive macOS authentication and preferences-window navigation. The
automated milestone coverage verifies view-model routing, destructive copy,
retryability, recovery-state branching, authentication language, and accessible
labels/hints.

**Exit gate:** A user can manage encryption without hidden state changes,
misleading Touch ID claims, or ambiguous destructive behavior.

### Milestone 7 — End-to-end security and release gate

**Objective:** Prove the complete feature against its threat model and document
the remaining limits before release.

**Status (2026-07-12):** Automated release artifacts implemented; manual
signed-app release checks remain pending.

- Added `HistorySecurityReleaseGateTests` covering clean-install plaintext
  bootstrap and 100 enable/disable cycles with consistent metadata, empty
  history, and no orphan keys in the test key store.
- Added `Resources/inspect_history_plaintext.py`, a repeatable raw marker
  scanner for SQLite DB/WAL/journal, legacy Realm paths, and PINCache/cache
  storage roots.
- Added `ENCRYPTION_AT_REST_RELEASE_CHECKLIST.md` with captured automated
  results, raw-inspection commands, manual app QA, performance checks,
  documentation checks, and PR-description non-goals.
- Updated `PRIVACY.md` and added `Resources/EncryptedHistoryHelp.md` to state
  in-memory exposure while unlocked, ThisDeviceOnly key loss, destructive mode
  transitions, encrypted-history/CloudKit incompatibility, backup/snapshot/SSD
  limitations, and snippets being out of scope.
- Verified with focused release-gate tests and the full Xcode test suite using
  Xcode 26.5 via xcrun with serial test execution. Test result: 133 tests in
  23 suites passed.

**Depends on:** Milestones 0 through 6.

**In scope:**

- Full automated suite and signed-app manual verification.
- Raw-storage inspection across supported clipboard types.
- Performance and memory characterization.
- Privacy/security documentation and release checklist.

**Deliverables:**

- End-to-end test checklist with captured results.
- Raw-database inspection utility or documented repeatable commands for tests.
- Updated PRIVACY.md and user-facing help.
- PR description stating all non-goals from section 1.

**Acceptance tests:**

- [x] Automated: clean install starts plaintext; upgrade fixture completes
      Milestone 0 migration with no user-visible regression.
- [ ] Manual app: enabling deletes old history, captures new text/image/RTF/PDF/
      URL history, locks, authenticates, and pastes the exact original values.
- [ ] Raw inspection: after encrypted capture and a clean application quit,
      database, WAL/journal files, caches, and active legacy paths contain none of
      the unique plaintext markers used by the test.
- [ ] Manual app: screen lock, fast-user switching, and sleep each require a new
      unlock before history access and do not capture while locked.
- [ ] Manual app: simulated missing key fails closed and clear-inaccessible-
      history returns to a usable empty state.
- [ ] Manual app: disabling deletes encrypted history and resumes empty plaintext
      capture without decrypting old rows.
- [ ] Performance: encryption, hashing, and thumbnail persistence run off the
      main thread; a benchmark report covers 1 MiB and 10 MiB assets and records
      latency plus peak memory without introducing a UI hang.
- [x] Reliability: 100 enable/disable cycles against temporary databases finish
      with consistent metadata, empty history at each transition, and no orphan
      Keychain records in the test store.
- [x] Documentation: explicitly states in-memory exposure while unlocked,
      ThisDeviceOnly key loss, destructive transitions, no encrypted CloudKit
      sync, and inability to scrub historical backups/APFS snapshots/SSD blocks.
- [ ] Release: no new third-party cryptography dependency is present and all
      security tests run in CI.

**Implementation note:** The raw-inspection command and manual/performance
checklists are now present, but the signed-app manual exercises and benchmark
measurements still need to be executed before a product release. The automated
suite did not add a third-party cryptography dependency and passes under the
serial Xcode command captured in the release checklist.

**Final release gate:** No known path may write plaintext history while database
mode is encrypted, transitional, inaccessible, unavailable, or corrupt. Any
failure to establish that invariant blocks release.
