# Encrypted Clipboard History

Clipy can optionally encrypt clipboard history stored on disk.

When you enable encrypted history:

- Clipy permanently clears existing clipboard history before encryption starts.
- Snippets are unaffected.
- New history is encrypted in Clipy's local history database.
- The history key is protected by macOS Keychain user authentication.
- Clipy locks encrypted history when your Mac sleeps, the session resigns, the
  screens sleep, the screensaver starts, or you choose Lock Now.

Important limits:

- While Clipy is running and unlocked, decrypted history and key material may be
  present in memory.
- The key is ThisDeviceOnly. It does not migrate to another Mac.
- If the Keychain item is lost or reset, encrypted history is unrecoverable.
  Clipy can clear inaccessible history and return to an empty usable state.
- Disabling encrypted history permanently clears encrypted history instead of
  decrypting it in place.
- Encrypted history cannot be used with iCloud/CloudKit history sync.
- Enabling encryption cannot remove old copies from Time Machine backups, APFS
  snapshots, SSD remanence, or other previously created copies.

For the strongest device-level protection, also enable FileVault and keep macOS
authentication protections active.
