# Encryption at Rest Release Checklist

Last updated: 2026-07-12

This checklist is the release gate for encrypted clipboard history at rest. A
release must not claim encrypted history support until every required manual
item is completed on a signed app build.

## Captured automated result

- Command:
  `xcrun xcodebuild CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -scheme Clipy -project Clipy.xcodeproj -derivedDataPath /private/tmp/clipy-derived -skipPackagePluginValidation -skipMacroValidation -parallel-testing-enabled NO -quiet test`
- Environment: Xcode 26.5, macOS test host.
- Result on 2026-07-12: 133 tests in 23 suites passed.
- Note: `-parallel-testing-enabled NO` is required because several Swift
  Testing suites exercise process-global history security state.

## Raw-storage inspection

Use unique marker strings for every payload type, for example:

- `CLIPY-E2E-TEXT-2026-07-12`
- `CLIPY-E2E-IMAGE-2026-07-12`
- `CLIPY-E2E-RTF-2026-07-12`
- `CLIPY-E2E-PDF-2026-07-12`
- `CLIPY-E2E-URL-2026-07-12`

After encrypted capture and a clean app quit, run:

```sh
python3 Resources/inspect_history_plaintext.py \
  --root "$HOME/Library/Application Support/com.clipy-app.Clipy" \
  --root "$HOME/Library/Caches/com.clipy-app.Clipy" \
  --marker "CLIPY-E2E-TEXT-2026-07-12" \
  --marker "CLIPY-E2E-IMAGE-2026-07-12" \
  --marker "CLIPY-E2E-RTF-2026-07-12" \
  --marker "CLIPY-E2E-PDF-2026-07-12" \
  --marker "CLIPY-E2E-URL-2026-07-12"
```

The command must exit 0. Any marker hit blocks release.

## Manual app checklist

- [ ] Clean install starts in plaintext mode with no user-visible regression.
- [ ] Enabling encryption clearly warns that current clipboard history will be
      permanently cleared and snippets are unaffected.
- [ ] Enable cancellation changes neither history, metadata, nor Keychain state.
- [ ] Enable retry after an injected failure returns to a consistent state.
- [ ] After enable, old history is gone and new text/image/RTF/PDF/URL captures
      round-trip exactly after unlock.
- [ ] Screen lock, fast-user switching, screensaver start, and system sleep each
      require a new unlock before history access.
- [ ] Clipboard changes made while encrypted history is locked are not captured.
- [ ] Unlock cancellation leaves history locked and does not repeatedly prompt.
- [ ] Simulated missing key fails closed; clear-inaccessible-history returns to
      usable empty plaintext history.
- [ ] Disable warns that encrypted history will be permanently cleared, deletes
      encrypted rows, deletes the key, and resumes empty plaintext capture
      without decrypting old rows.

## Performance checklist

- [ ] Measure encrypted capture for 1 MiB assets.
- [ ] Measure encrypted capture for 10 MiB assets.
- [ ] Record latency and peak memory.
- [ ] Confirm hashing, encryption, and thumbnail persistence do not introduce a
      visible UI hang.

## Documentation checklist

- [ ] User-facing help and privacy docs state that decrypted values and the key
      can exist in memory while unlocked.
- [ ] Docs state that the key is ThisDeviceOnly and lost/reset keys make
      encrypted history unrecoverable.
- [ ] Docs state that enabling/disabling encryption clears clipboard history.
- [ ] Docs state that encrypted history is incompatible with CloudKit/iCloud
      history sync.
- [ ] Docs state that enabling encryption cannot scrub historical backups, APFS
      snapshots, SSD remanence, or other prior copies.

## PR description template

Encrypted clipboard history at rest:

- Adds app-level AES-256-GCM encryption for clipboard history payloads,
  thumbnails, titles, and OCR text.
- Protects the history key with macOS Keychain user-presence authentication.
- Uses destructive transitions: enabling clears plaintext history; disabling
  clears encrypted history; snippets are unaffected.
- Locks on session/screen/sleep/screensaver events and supports explicit lock
  and unlock from the Security preferences pane.

Security limits/non-goals:

- While Clipy is running and unlocked, decrypted values and key material may
  exist in process memory.
- The key is ThisDeviceOnly and cannot migrate to another Mac.
- If the Keychain item is lost or reset, encrypted history is unrecoverable; the
  app must fail closed and offer destructive recovery.
- Encrypted history and iCloud/CloudKit history sync are mutually exclusive.
- Enabling encryption cannot retroactively protect Time Machine backups, APFS
  snapshots, SSD remanence, or other prior copies.
- This feature protects clipboard history only; snippets are out of scope.
