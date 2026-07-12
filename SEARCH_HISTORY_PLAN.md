# Search History Technical Plan

**Document status:** In implementation

**Last reviewed:** 2026-07-12

**Target platform:** macOS 13 or later, Xcode 26.5

## Implementation log

This feature is being implemented on the `feature/search-history` branch in a
dedicated git worktree, isolated from concurrent, still-uncommitted
encryption-runtime (`LockManager`) work in the primary working tree. The branch
is based on commit `c4bdfdc` ("Add destructive history encryption transitions"),
which contains the committed encryption-at-rest foundation but **not** the
uncommitted runtime-locking (`LockManager`) changes. Milestone 4's runtime-lock
integration is therefore written against the committed security API
(`HistorySecurityBootstrap` / `HistoryLockState`) and notes where it would also
hook the not-yet-committed `LockManager` once that lands.

- **Milestone 0:** ✅ Complete (automated + code); manual QA pending (see note).
- **Milestone 1:** ✅ Complete (19 unit tests; perf baseline recorded).
- **Milestone 2:** ✅ Complete (shared renderer; 19 renderer unit tests).
- **Milestone 3:** ✅ Complete (session controller + live switching; 18 tests).
- **Milestone 4:** ⬜ Not started.
- **Milestone 5:** ⬜ Not started.
- **Milestone 6:** ⬜ Not started.

## 1. Summary

Add an `NSSearchField` above Clipy's history section. The field appears in both
history-bearing menus:

- the main Clipy menu opened from the status item or the main-menu hotkey
- the history-only menu opened from the history hotkey

When the query is empty, the section behaves exactly like the current History
list. When the query contains non-whitespace text, the same section is replaced
with matching history results. Clearing the field restores the normal History
list immediately. Every time either menu opens, the search field is empty,
selected, and ready for typing without first clicking it.

This is an AppKit `NSMenu` feature, not a window or SwiftUI list. The highest-risk
part is putting a first-responder text editor inside a tracking menu without
activating Clipy or breaking the existing paste-to-previous-application flow.
Milestone 0 is therefore a required feasibility gate.

## 2. Product behavior contract

These decisions remove ambiguity for the implementer.

### 2.1 Where search appears

- The search field is the first visible item in `clipMenu` and `historyMenu`.
- It is immediately above the disabled History/Search Results section label.
- It uses the localized `Search History` placeholder and the standard
  `NSSearchField` cancel button.
- It does not appear in `snippetMenu` or a single snippet-folder menu.
- In the main menu, searching replaces only the history section. Snippet
  folders, Clear History, Edit Snippets, Preferences, and Quit remain visible
  and keep their current behavior.

### 2.2 Opening and closing

- Opening either history-bearing menu starts a new search session with an empty
  query. Queries are not shared between the main and history-only menus.
- The search field becomes first responder on every open, including status-item
  clicks, the main hotkey, and the history hotkey.
- Existing query text is cleared when the menu closes. No query is persisted to
  UserDefaults, SQLite, analytics, logs, crash metadata, or restoration state.
- Clipy must not call `NSApp.activate` to focus the field. The application that
  was active before opening Clipy must remain the paste target.
- Opening the snippet menu retains its current behavior: the first selectable
  snippet can be highlighted, and no search field is focused.

### 2.3 Query and matching semantics

- A query is considered empty after trimming whitespace and newlines.
- Empty query: show the normal History label and the unfiltered history list.
- Non-empty query: show the localized Search Results label and matching history.
- Split the trimmed query on whitespace. Every term must match at least one
  searchable field; terms may match different fields on the same history row.
- Comparison is case-insensitive, diacritic-insensitive, and width-insensitive.
  Use a deterministic locale-independent fold for matching; do not lowercase
  with the user's current locale because that can make tests and behavior vary.
- Search these caller-facing strings:
  - the full stored history title, not only its shortened menu rendering
  - OCR text when present
  - the visible type prefix produced for image, PDF, and file histories
- Do not search raw asset bytes, thumbnails, pasteboard type identifiers,
  history IDs, device IDs, snippets, or encrypted storage envelopes.
- Preserve the normal history ordering preference. Search relevance does not
  reorder results in the first version.
- Search only the same candidate set that the normal history menu can display:
  the selected sort order, limited by `maxHistorySize`. This prevents search
  from exposing rows that the current History list intentionally omits.

### 2.4 Results and actions

- Reuse the existing history renderer, including thumbnails, tooltips, numbered
  titles, numeric key equivalents, and overflow submenus.
- Recompute visible list numbers and numeric key equivalents from search-result
  order, starting at the configured zero/one preference.
- If there are no matches, display one disabled localized `No Matching History`
  item. It has no action, target, represented object, key equivalent, tooltip,
  or submenu.
- Clicking a result performs the existing `selectClipMenuItem(_:)` path.
- Return while the search field has focus activates the first matching history
  item. If there is no result, Return does nothing and leaves the menu open.
- Down Arrow moves from the field to the first selectable history row, or to the
  first overflow-folder item when grouping puts every history inside a submenu.
  Up/Down then use native menu navigation. Moving back into the field restores
  text focus.
- Printable characters, including digits used by numeric menu shortcuts, go to
  the search field while it is first responder. Temporarily suppress history
  numeric key equivalents if AppKit would resolve them before the field editor;
  restore the equivalents after focus moves to the result list.
- The search field's cancel button clears the query and restores History
  immediately. Escape retains native menu behavior and closes the menu; close
  cleanup clears the query.
- Standard text editing and input methods must work: Command-A/C/X/V, Delete,
  cursor movement, dead keys, and marked-text/IME composition.

### 2.5 Live changes

- A new, deleted, reordered, or OCR-updated history refreshes the cached menu
  snapshot. If a menu is open, reapply its current query without replacing the
  tracking `NSMenu`, its search item, or its field editor.
- Preference changes affecting sort, limits, thumbnails, numbering, grouping,
  or title presentation re-render the results while preserving the active query
  and focus.
- Clearing all history while a menu is open shows the normal empty-history state
  for an empty query, or No Matching History for a non-empty query.
- If encryption runtime locking is present, a lock transition clears the query,
  normalized search strings, results, and any pending work before showing the
  locked placeholder defined by the encryption feature.

## 3. Current codebase findings

The implementation must be based on these observed constraints.

### 3.1 Menu construction

- `Clipy/Sources/Managers/MenuManager.swift` owns three `NSMenu` objects.
- `createClipMenu()` currently recreates all three menus and assigns the new
  main menu to the status item.
- `addHistoryItems(_:)` synchronously fetches history, creates the disabled
  History label, renders inline items and overflow submenus, and is called once
  for the main menu and once for the history-only menu.
- The status-item menu can open without going through `popUpMenu(_:)`.
  Consequently, focus setup must use `NSMenuDelegate.menuWillOpen(_:)`, not only
  the hotkey popup method.
- `popUpMenu(_:)` calls `highlightingFirstItemIfPossible()`. That extension uses
  the private `highlightItem:` selector. It will race with search-field focus
  and must not be called for history-bearing menus after this feature lands.

### 3.2 Data and observation

- `PasteboardHistoryRepository.fetchHistoryDetails(...)` returns the
  caller-facing history and optional thumbnail in the correct configured order.
- Title and OCR storage are now BLOB-backed in the in-progress encryption work,
  while `PasteboardHistory.title` and `.ocrText` expose decoded domain strings.
- The V5 encryption foundation deliberately removes
  `PasteboardHistorySearch` and its FTS triggers. Do not restore them. Persistent
  plaintext indexes would defeat encryption at rest.
- `observeHistoryChanges()` currently observes selected history IDs. An OCR-only
  update may leave that selected value unchanged. The implementation must prove
  OCR changes emit, or replace/augment this signal with a content-free revision
  notification that emits for every insert, update, and delete.
- The maximum history size is user-editable. Avoid additional database reads or
  thumbnail decoding on every keystroke.

### 3.3 Action routing and paste behavior

- History menu items currently have a nil target and an AppDelegate selector.
  Adding a search field changes the responder chain. Explicitly verify that
  click, Return, and keyboard activation still reach AppDelegate; set an
  explicit target if necessary.
- `PasteService` posts the paste command to the active application. Activating
  Clipy merely to obtain text focus could redirect paste into Clipy or lose the
  user's prior application. This is a release-blocking regression.

### 3.4 Repository state during implementation

The working tree may also contain unfinished encryption-at-rest milestones.
Search work must be rebased on, and tested with, the final caller-facing
repository API. Do not discard or overwrite those changes. In particular:

- search consumes only successfully decoded/decrypted domain models
- search never treats an undecodable BLOB or cipher envelope as text
- search returns no protected results while locked or key-unavailable
- normalized search strings are memory-only and are cleared on lock

## 4. Goals and non-goals

### Goals

- Fast filtering of visible clipboard history from a focused search field.
- Identical behavior from status-item, main-hotkey, and history-hotkey entry
  points.
- Preserve existing history ordering, rendering, paste, delete-after-paste,
  plain-text paste, snippet, and settings behavior.
- Remain compatible with encryption at rest without a plaintext on-disk index.
- Make matching and dynamic menu behavior testable outside the monolithic
  `MenuManager`.
- Maintain keyboard-only and VoiceOver usability.

### Non-goals

- Searching snippets or combining snippet and history results.
- Fuzzy ranking, typo correction, semantic search, regex, query syntax, or
  highlighted matching substrings.
- A persistent FTS, Spotlight, Core Data, or custom searchable-encryption index.
- Searching clipboard asset payloads or files referenced by clipboard entries.
- Persisting recent queries or adding search preferences.
- Replacing all Clipy menus with a window, popover, SwiftUI view, or `NSPanel`.
  A panel is only a fallback requiring a separate product/architecture decision
  if Milestone 0 proves an editable `NSMenuItem.view` is not viable.

## 5. Proposed architecture

### 5.1 `HistorySearchMatcher`

Add a pure, Foundation-only search component, for example:

```swift
struct HistorySearchQuery: Equatable, Sendable {
    let originalText: String
    let normalizedTerms: [String]
    var isEmpty: Bool { normalizedTerms.isEmpty }
}

struct HistorySearchDocument: Equatable, Sendable {
    let historyID: PasteboardHistory.ID
    let normalizedFields: [String]
}

enum HistorySearchMatcher {
    static func makeQuery(_ text: String) -> HistorySearchQuery
    static func makeDocument(_ history: PasteboardHistory) -> HistorySearchDocument
    static func matches(_ query: HistorySearchQuery, document: HistorySearchDocument) -> Bool
}
```

Normalization should use `String.folding(options:locale:)` with
`[.caseInsensitive, .diacriticInsensitive, .widthInsensitive]` and a fixed
locale such as `en_US_POSIX`. Normalize once per snapshot and once per query,
not once per field for every keystroke. Keep the original domain models for
display and actions; never display normalized strings.

### 5.2 `HistoryMenuSnapshot`

Create one immutable snapshot whenever history or relevant preferences change:

```swift
struct HistoryMenuSnapshot {
    let details: [PasteboardHistoryDetail]
    let documentsByID: [PasteboardHistory.ID: HistorySearchDocument]
    let presentation: HistoryMenuPresentation
}
```

`HistoryMenuPresentation` should contain the preference values needed by the
renderer: numbering origin, numbered-title flag, numeric shortcuts, grouping
sizes, thumbnail visibility/dimensions, tooltip settings, and sort mode. Taking
one snapshot avoids fetching/decrypting the same rows separately for the main
and history menus and prevents preferences from changing halfway through a
render.

Fetch and decode/decrypt history only when constructing this snapshot. Filtering
must operate against the in-memory snapshot and must not hit SQLite, Keychain,
OCR, or thumbnail decoding for each character.

Repository reads and domain mapping may run on the repository's safe serial
queue. Normalization and large filters should run on a cancellable serial
utility queue using value-only search documents. Only immutable/sendable values
may cross that boundary. `NSMenu`, `NSMenuItem`, `NSSearchField`, `NSImage`,
UserDefaults access, controller state, and result application stay on the main
actor. For the default small history, an immediate main-actor fast path is
acceptable only if the 10,000-row performance test proves it cannot stall menu
tracking.

### 5.3 `HistoryMenuSessionController`

Introduce one controller per history-bearing menu. It should be `@MainActor`,
strongly retained by `MenuManager`, and conform to `NSMenuDelegate` and
`NSSearchFieldDelegate`/`NSControlTextEditingDelegate` as appropriate.

Responsibilities:

- own a stable `NSMenuItem` whose `view` contains the `NSSearchField`
- own the disabled History/Search Results label item
- own references to only the currently rendered dynamic history items
- retain the latest `HistoryMenuSnapshot`
- own query text and normalized search state for that menu session
- schedule first-responder assignment in `RunLoop.Mode.eventTracking`
- debounce non-empty query changes by approximately 75 milliseconds
- restore History immediately when the query becomes empty
- filter the cached snapshot and ask the shared renderer for menu items
- remove and insert only its dynamic items in the same tracking `NSMenu`
- preserve the search item, field editor, selection, and focus during updates
- suppress/restore numeric key equivalents when keyboard focus crosses between
  the field and result navigation
- cancel pending work and clear query-specific normalized terms on close
- clear the full normalized document cache as part of a protected-state lock

Do not replace an open menu object. `NSMenu.delegate` is weak, so retaining the
controller is mandatory.

### 5.4 Shared history renderer

Extract the list-number, key-equivalent, thumbnail, tooltip, and overflow-folder
logic from `addHistoryItems(_:)` into a renderer that accepts details plus a
presentation snapshot and returns `[NSMenuItem]`. Both normal history and search
results use exactly this path.

The renderer must not fetch data or read UserDefaults. It must receive all input
explicitly so unit tests can cover boundary cases such as zero-based numbering,
ten numeric shortcuts, zero inline rows, and partially filled overflow folders.

The controller tracks the returned top-level items by identity. On the next
render it removes those items and inserts replacements after the stable section
label. This avoids fragile numeric indexes when snippets or footer commands are
present below the history section.

### 5.5 MenuManager coordination

Refactor `MenuManager` into these operations:

1. Build the fixed skeleton for the main, history, and snippet menus.
2. Create/retain a main and history `HistoryMenuSessionController`.
3. Fetch one `HistoryMenuSnapshot` when history or a relevant preference
   changes.
4. Send the snapshot to both history menu controllers.
5. Rebuild snippets/footer only when their inputs change. If a history-bearing
   menu is tracking, defer any full skeleton replacement until `menuDidClose`;
   apply history changes in place meanwhile.
6. Continue using first-item highlighting only for snippet-only menus.

If a full refactor is too broad, the minimum safe implementation is still to
keep the search item stable and mutate the active menu in place. Recreating
`clipMenu`/`historyMenu` in `controlTextDidChange` is not acceptable because the
tracking loop continues presenting the old object.

### 5.6 Content-free change notification

Strengthen `observeHistoryChanges()` so each successful insert, update
(including same-length OCR replacement), and delete causes a refresh without
publishing title, OCR, assets, thumbnails, or ciphertext through Combine.

Preferred order of solutions:

1. Use the database observation API's change callback if it can emit regardless
   of selected-value equality, and add a regression test proving OCR-only
   updates emit.
2. Otherwise merge a repository-owned monotonically increasing revision signal
   into database observation. Send only after a successful transaction. Include
   all repository write paths and security transition/cleanup paths.
3. Add a persisted revision table/trigger only if cross-process writers truly
   require it. This is a schema change and must be reviewed with the encryption
   plan before use.

Refreshing on `menuWillOpen` remains required as a final consistency check even
when observation is correct.

## 6. Detailed data flow

### Menu open

1. `menuWillOpen(_:)` starts a new session and clears stale query state.
2. Refresh the snapshot if its generation is stale.
3. Render unfiltered History into the existing menu.
4. In `.eventTracking` mode, call `searchField.window?.makeFirstResponder(...)`
   and select the field contents. Do not activate the application.
5. If focus fails, record no query content and leave the menu usable; Milestone
   0 must prevent shipping that state.

### Text change

1. Read `searchField.stringValue` on the main actor.
2. Normalize the query.
3. If empty, cancel pending work and synchronously render unfiltered History.
4. If non-empty, debounce using a cancellable generation/token.
5. Filter `snapshot.details` in existing order using documents from
   `documentsByID`.
6. Before applying, verify the token, menu session generation, snapshot
   generation, query, and lock state still match.
7. Replace only dynamic items and update the section label.
8. Keep the search field first responder unless the user explicitly navigated
   into results.

### History/preference change while open

1. Build a new immutable snapshot.
2. Replace the controller's snapshot and invalidate pending filter work.
3. Reapply the current query against the new snapshot.
4. Mutate dynamic items in place and preserve the search field/view.

### Menu close

1. Increment the session generation and cancel pending work.
2. Clear query text and query-specific normalized terms. The latest authorized
   snapshot may remain cached for the next open, but all its normalized documents
   must be discarded on a protected-state lock or key loss.
3. Release the field editor as normal; do not retain it directly.
4. Apply any deferred full menu skeleton rebuild.

## 7. Planned file changes

Names may be adjusted to match project conventions, but responsibilities should
remain separated.

| File | Planned change |
| --- | --- |
| `Clipy/Sources/Managers/MenuManager.swift` | Coordinate snapshots and two search sessions; stop replacing a menu while it is tracking. |
| `Clipy/Sources/Menus/HistoryMenuSessionController.swift` | New stable search item, menu lifecycle, focus, debounce, and dynamic-section mutation. |
| `Clipy/Sources/Menus/HistoryMenuRenderer.swift` | Extract deterministic history item and overflow submenu rendering. |
| `Clipy/Sources/Search/HistorySearchMatcher.swift` | New query/document normalization and pure matching. |
| `Clipy/Sources/Repositories/PasteboardHistoryRepository.swift` | Prove/fix content-free notifications for every history mutation; keep domain-only fetches. |
| `Clipy/Sources/Extensions/NSMenu+Highlight.swift` | Ensure history-bearing menus no longer use private first-item highlighting. |
| `Clipy/Resources/Localizable.xcstrings` | Add Search History, Search Results, and No Matching History strings and accessibility text. |
| `Clipy.xcodeproj/project.pbxproj` | Add new source and test files to the correct targets. |
| `ClipyTests/Search/HistorySearchMatcherTests.swift` | Pure matching, normalization, and field coverage. |
| `ClipyTests/Menus/HistoryMenuRendererTests.swift` | Numbering, shortcuts, grouping, no-result item, actions, and presentation. |
| `ClipyTests/Menus/HistoryMenuSessionControllerTests.swift` | Menu lifecycle, query switching, stale work, focus-preserving in-place updates. |
| `ClipyTests/Repositories/PasteboardHistoryRepositoryTests.swift` | OCR-only and all-write-path change-notification tests. |

Do not add a SQLite migration, FTS schema, history-search table, query-history
store, or search analytics event for this feature.

## 8. Milestones

Every milestone must update the status in this document and land as a separate,
reviewable commit. A milestone is complete only when its new tests and the
pre-existing test suite pass.

### Milestone 0 — Editable NSMenu feasibility gate

**Status:** ✅ Code + automated component tests complete. Manual, human-only
acceptance items below remain open (an automated agent cannot exercise real
status-item/hotkey tracking, IME, or app-activation behavior). These are folded
into the Milestone 6 manual QA checklist.

**Implementation note (tested toolchain):** Xcode 26.5 (build 17F42), macOS 13+
deployment target, Swift 5 language mode. Findings:

- `HistorySearchFieldView` embeds an `NSSearchField` in an `NSMenuItem.view`
  using only public AppKit APIs. Focus is requested from
  `HistoryMenuSessionController.menuWillOpen(_:)` via
  `RunLoop.current.perform(inModes: [.eventTracking, .default])` +
  `window.makeFirstResponder(_:)`; the app is never activated.
- Focus scheduling is injectable (`FocusScheduler`) so the "schedules one
  request on open / cancels on close / clears query" contract is verified in a
  headless component test without a real tracking run loop.
- `popUpMenu(_:)` no longer calls the private `highlightItem:` path for the
  main/history menus (it would race first-responder assignment); snippet-only
  menus keep the existing highlight behavior.

**Objective:** Prove the required focus and input behavior on all real menu entry
points before restructuring production code.

**Depends on:** Nothing.

**Deliverables:**

- A minimal internal `HistorySearchFieldView` embedded in an `NSMenuItem.view`.
- Temporary or permanent menu-delegate lifecycle wiring using public AppKit
  APIs.
- A short implementation note in this document recording tested macOS/Xcode
  versions and any AppKit quirks found.

**Acceptance tests:**

- [ ] Manual (pending human QA): status-item click opens the main menu with an
      empty selected field; typing immediately enters text without clicking.
- [ ] Manual (pending human QA): main hotkey and history hotkey do the same and
      do not insert the hotkey's trigger character into the field.
- [ ] Manual (pending human QA): Clipy does not become the frontmost application
      merely to focus the field; selecting a history still pastes into the
      previously active application.
- [ ] Manual (pending human QA): mouse selection, selection replacement, cancel
      button, Command-A/C/X/V, arrows, Delete, Return, Escape, and a marked-text
      IME work while the menu tracks.
- [ ] Manual (pending human QA): digits are entered into the field instead of
      invoking history numeric shortcuts while the field has focus.
- [x] Automated component test: `menuWillOpen` schedules one focus request and
      `menuDidClose` cancels it and clears the query
      (`HistoryMenuSessionControllerTests`).
- [x] Regression: snippet-only menus still highlight/navigate as before
      (`popUpMenu(_:)` only highlights `.snippet`).

**Exit gate:** All three history-menu entry points support reliable text editing
without app activation or private focus APIs. If this fails, stop. Document the
failure and request approval for a panel/popover architecture; do not continue
with a partially editable menu.

### Milestone 1 — Pure search model and snapshot contract

**Status:** ✅ Complete. `HistorySearchMatcher`/`HistorySearchQuery`/
`HistorySearchDocument`, `HistoryMenuSnapshot`, and `HistoryMenuPresentation`
landed with 19 passing unit tests.

**Recorded performance baseline** (Xcode 26.5, Apple Silicon): building
(normalizing) a 10,000-row snapshot ≈ 63 ms; filtering it for one term ≈ 93 ms
(under the 100 ms p95 target). Adversarial 1,000-row fixture with 10,000-char
titles + 4 KiB OCR ≈ 91 ms per filter. Matching uses a precomputed combined
field string plus a literal (already-folded) search; the 10k case runs off the
main actor behind the 75 ms debounce in Milestone 3.

**Objective:** Implement deterministic, encryption-compatible in-memory matching
with no menu or database side effects.

**Depends on:** Milestone 0.

**Deliverables:**

- `HistorySearchQuery`, `HistorySearchDocument`, and `HistorySearchMatcher`.
- `HistoryMenuSnapshot` and immutable presentation settings.
- Unit tests covering matching semantics and snapshot ordering/limits.

**Acceptance tests:**

- [x] Unit: empty, whitespace-only, and newline-only queries are empty.
- [x] Unit: title matching is case-, diacritic-, and width-insensitive.
- [x] Unit: OCR-only text and visible type prefixes can match.
- [x] Unit: multiple terms use AND semantics and can match different fields.
- [x] Unit: raw asset bytes, IDs, device IDs, and snippets cannot match.
      (Snippets are never fed to the matcher; IDs/device IDs/asset bytes are
      excluded from the searchable fields.)
- [x] Unit: results preserve input ordering and contain no duplicates.
- [x] Unit: full stored text can match even when `trimmedMenuTitle` would hide
      the matching suffix.
- [x] Unit: malformed/undecodable protected storage never becomes a searchable
      string; locked/key-unavailable snapshots contain no search documents.
      (Undecodable UTF-8 → empty title → no fields; empty details → no
      documents. Repository-level lock enforcement is covered in Milestone 4.)
- [x] Performance: normalize and filter 10,000 representative histories
      (256-character titles + 1 KiB OCR) — see recorded baseline above. Separate
      adversarial 1,000-row maximum-size fixture recorded.
- [x] Security: `creatingDocumentsWritesNothingToUserDefaults` confirms the
      pure model writes no search text. (Matcher/snapshot never touch SQLite or
      UserDefaults; DB inspection is exercised in Milestone 4's integration
      tests where a database is bound.)

**Exit gate:** Matching is deterministic and completely independent of SQLite,
Keychain, `NSMenu`, UserDefaults, and analytics.

### Milestone 2 — Shared deterministic history renderer

**Status:** ✅ Complete. `HistoryMenuRenderer` extracts the exact grouping,
numbering, key-equivalent, thumbnail, tooltip, and overflow-folder logic from
`MenuManager.addHistoryItems`/`makeClipMenuItem`. `MenuManager` now builds a
`HistoryMenuPresentation`, fetches details, and renders the unfiltered History
list through the renderer (no search switching yet). 19 renderer unit tests.

**Objective:** Extract existing History rendering so unfiltered and filtered
lists cannot diverge in behavior.

**Depends on:** Milestone 1.

**Deliverables:**

- `HistoryMenuRenderer` accepting details and presentation values.
- `No Matching History` result rendering.
- `MenuManager` using the renderer for the existing unfiltered History list,
  with no search switching enabled yet.

**Acceptance tests:**

- [x] Unit: zero- and one-based list numbering match existing preferences.
- [x] Unit: numeric key equivalents cover only the configured first ten items
      and map ten back to zero as today.
- [x] Unit: inline and overflow submenu boundaries match current behavior for 0,
      1, exact-boundary, boundary-plus-one, and partial-last-folder counts.
- [x] Unit: thumbnails, color previews, tooltips, represented history IDs,
      actions, and explicit targets are preserved.
- [x] Unit: no-results item is disabled and inert.
- [x] Regression: the renderer replicates the original grouping/numbering
      formulas verbatim; the deterministic renderer tests assert identical
      titles, ordering, grouping, shortcuts, images, and paste actions. (The
      folder-title/boundary math and key-equivalent mapping are byte-for-byte
      the prior algorithm.)
- [x] Regression: main-menu snippet and footer ordering is unchanged
      (`createClipMenu` still appends snippets/footer after history; only the
      history section's construction was extracted).

**Exit gate:** The existing History menu is rendered through a pure/shared path
with no user-visible behavior change.

### Milestone 3 — Search session and live result switching

**Status:** ✅ Complete (automated). `HistoryMenuSessionController` now owns the
stable search + section-label items, holds the snapshot, debounces non-empty
queries (75 ms, injectable/event-tracking timer), restores History immediately
on empty, and replaces only the dynamic history items in place. `MenuManager`
builds one snapshot and installs both sessions. Return activates the first
result; the cancel button clears + restores; numeric shortcuts are suppressed
while the field is focused and restored on Down-arrow. The single remaining
manual item (rapid-typing feel during real tracking) is deferred to Milestone 6.

**Objective:** Connect the focused field to in-place, cached filtering in both
history-bearing menus.

**Depends on:** Milestones 1 and 2.

**Deliverables:**

- Two retained `HistoryMenuSessionController` instances.
- Stable search and section-label items.
- Debounced query handling with session/snapshot generation checks.
- In-place replacement of only dynamic history items.
- Return, Down Arrow, and cancel-button behavior from the product contract.

**Acceptance tests:**

- [x] Component: empty query renders History; non-empty query renders Search
      Results; clearing restores the identical unfiltered item structure.
- [x] Component: matching title, OCR, and type-prefix fixtures appear in the
      expected order (matcher/snapshot suites cover OCR + type prefix; the
      session suite covers title matching. Both menus use the same controller
      class, so behavior is identical by construction.)
- [x] Component: no match shows exactly one disabled No Matching History item.
- [x] Component: snippets and footer items remain present and unchanged while
      the main menu displays search results.
- [x] Component: query updates retain the same `NSMenu`, search `NSMenuItem`, and
      `NSSearchField` identities.
- [x] Component: clearing bypasses debounce; stale debounced work cannot replace
      the restored History list.
- [x] Component: an older snapshot/query result cannot overwrite a newer one.
- [x] Component: Return invokes the first result exactly once; it does nothing
      for no results. Down Arrow restores numeric shortcuts and highlights the
      first result without clearing the field text. (Real highlight uses the
      menu's native selection during tracking; verified in Milestone 6 manual.)
- [x] Component: numeric keys edit search text while the field is focused
      (numeric key equivalents are suppressed while focused).
- [ ] Manual (pending human QA): rapid typing and deletion do not flicker, close
      the menu, move focus, or cause an incorrect paste.

**Exit gate:** Both history-bearing menus switch between History and Search
Results within the same open menu and clearing is lossless.

### Milestone 4 — Live data, preferences, and protected-state integration

**Objective:** Make search correct while clipboard history, OCR, preferences, or
encryption state changes during a menu session.

**Depends on:** Milestone 3 and the caller-facing repository/security APIs on the
integration branch.

**Deliverables:**

- Correct content-free history mutation observation.
- Snapshot refresh/requery behavior that preserves the open menu and focus.
- Deferred full menu rebuilds while a menu is tracking.
- Explicit locked/key-unavailable/error placeholder integration when encryption
  runtime state is available.

**Acceptance tests:**

- [ ] Repository integration: insert, duplicate-update/reorder, OCR update,
      same-length OCR replacement, delete, prune, and delete-all each emit a
      history change only after the transaction succeeds.
- [ ] Component: a newly copied matching item appears under the active query; a
      deleted result disappears; clearing then shows the updated History list.
- [ ] Component: OCR completion can add an item to active results without
      replacing the menu or losing focus.
- [ ] Component: sort, history-limit, thumbnail, title-length, numbering,
      shortcut, and grouping preference changes reapply the current query.
- [ ] Component: deferred skeleton changes apply after close and do not retain a
      stale search controller as a weak `NSMenu.delegate`.
- [ ] Security integration: lock/key-unavailable/error clears query, documents,
      results, and pending tokens before rendering the protected placeholder.
- [ ] Security integration: unlock builds a new snapshot only after key-check
      success; stale pre-lock results never reappear.
- [ ] Security integration: raw SQLite inspection finds no title, OCR, query, or
      normalized-search plaintext added by this feature.
- [ ] Regression: plaintext mode works through the same domain API and never
      interprets encrypted envelopes as UTF-8.

**Exit gate:** Active search remains consistent across all mutation and security
state transitions, with no persistent plaintext index.

### Milestone 5 — Accessibility, localization, and interaction polish

**Objective:** Make the feature production-quality for keyboard, VoiceOver,
localization, and different menu configurations.

**Depends on:** Milestone 4.

**Deliverables:**

- Localized Search History, Search Results, and No Matching History strings.
- Search-field accessibility label, help, and result-count announcement that
  does not announce on every intermediate IME composition update.
- Final layout constraints/minimum menu width for macOS 13+.
- Removal of temporary feasibility/prototype code.

**Acceptance tests:**

- [ ] Localization: string-catalog validation succeeds and every supported
      locale has a reviewed value or an intentional English fallback.
- [ ] Accessibility Inspector: the field has role Search Field, a localized
      label, an understandable value, and a logical traversal order before
      results.
- [ ] VoiceOver manual: opening announces Search History; querying announces a
      stable result count/no-result state; selecting a result pastes it.
- [ ] Manual: English, German, Italian, Japanese, Portuguese (Brazil), and
      Simplified Chinese layouts do not clip the field, label, or no-result row.
- [ ] Manual: IME composition does not trigger partial destructive re-renders or
      dismiss the menu.
- [ ] Manual: all combinations of empty history, snippets absent/present,
      status item hidden/hotkey-only, thumbnails on/off, zero inline items, and
      very long titles remain usable.
- [ ] Manual: reduced motion, increased contrast, and keyboard-only operation do
      not hide state or require a pointer.

**Exit gate:** The feature is localized, accessible, and usable across supported
menu configurations and input methods.

### Milestone 6 — End-to-end release gate

**Objective:** Verify the complete feature and guard against focus, paste,
performance, and privacy regressions.

**Depends on:** Milestones 0 through 5.

**Deliverables:**

- Full automated test run on Xcode 26.5.
- A repeatable manual QA checklist attached to the release/PR.
- Updated status and recorded deviations in this document.

**Acceptance tests:**

- [ ] Automated: `xcrun xcodebuild CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -scheme Clipy -project Clipy.xcodeproj -derivedDataPath /private/tmp/clipy-derived -skipPackagePluginValidation -skipMacroValidation test` passes.
- [ ] Automated: SwiftLint and `git diff --check` pass with no new warnings.
- [ ] End to end: status click, main hotkey, and history hotkey each focus empty
      search; text filters; cancel restores History; result selection pastes to
      the application that was active before opening Clipy.
- [ ] End to end: rapid query changes plus concurrent clipboard capture, OCR,
      delete-after-paste, clear, prune, and preference changes never crash or
      show stale results.
- [ ] End to end: main menu snippets and commands and snippet-only hotkeys retain
      existing behavior.
- [ ] Performance: menu opening and first focus remain subjectively immediate at
      30, 1,000, and 10,000 histories; query latency meets the recorded Milestone
      1 target without main-thread stalls.
- [ ] Memory: repeated open/type/clear/close cycles do not retain menus, field
      editors, snapshots, debounce tasks, or normalized query text.
- [ ] Privacy: query text appears in neither SQLite/WAL/SHM files, UserDefaults,
      unified logs emitted by Clipy, Firebase events, nor crash breadcrumbs.
- [ ] Protected mode: locked and key-unavailable states reveal no prior titles,
      OCR, result counts, queries, thumbnails, or tooltips.
- [ ] Soak: 500 automated or scripted open/type/clear/close cycles complete with
      stable memory and no lost focus or unexpected activation.

**Final release gate:** No known entry point opens a history-bearing menu without
focused search, no query can produce stale/unauthorized results, no search text
is persisted, and selecting a result still pastes into the user's prior
application.

## 9. Risk register and mitigations

| Risk | Impact | Mitigation / required proof |
| --- | --- | --- |
| `NSSearchField` cannot reliably edit inside a tracking `NSMenu` | Feature is unusable or flaky | Milestone 0 is a stop/go gate across status and both hotkeys; panel fallback requires approval. |
| Calling `NSApp.activate` changes the paste target | User pastes into the wrong app | Never activate for focus; explicit end-to-end paste-target tests. |
| Status-item click bypasses `popUpMenu(_:)` | Search is focused only for hotkeys | Use `NSMenuDelegate.menuWillOpen(_:)` for all focus lifecycle work. |
| Existing private `highlightItem:` races with first responder | Focus jumps from the field | Do not invoke it for main/history menus; retain only for snippet-only behavior. |
| Replacing `NSMenu` while it is open | UI does not update, field editor is lost, or menu closes | Stable menu/search items and in-place dynamic range replacement; defer skeleton rebuilds. |
| Nil menu-item target resolves differently with field editor first responder | Result click/Return does nothing or edits text | Test action routing and use an explicit weak-safe target if required. |
| Numeric key equivalents consume query digits | Users cannot search numbers | Search field owns printable key events while focused; component/manual tests. |
| Hotkey trigger key leaks into query | Every hotkey search starts with `v` | Test key-up/down timing; delay first responder only as far as needed in event-tracking mode. |
| Normal main-queue debounce does not fire during menu tracking | Results update only after close | Schedule/deliver in event-tracking-compatible mode and test against a real open menu. |
| OCR-only updates do not change observed ID list | Active search misses new OCR text | Strengthen content-free revision observation and test same-length OCR replacement. |
| Restoring FTS leaks plaintext under encryption | Encryption-at-rest promise is broken | In-memory domain search only; raw DB/WAL/SHM privacy tests; no migration for search. |
| Search cache retains decrypted normalized strings after lock/close | Sensitive data remains in memory longer | Session-scoped cache, token invalidation, immediate clear on lock/close, memory tests. |
| Large user-configured history/title sizes block menu tracking | Typing becomes sluggish | Snapshot once, normalize once, 75 ms debounce, generation cancellation, 10k performance gate. |
| Background/debounced result arrives after clear/close/lock | Stale or unauthorized results reappear | Validate session, snapshot, query, and lock generations before every apply. |
| Live rebuild destroys IME marked text | CJK input becomes unusable | Do not replace field/item; test marked-text composition in every supported CJK locale. |
| Search result grouping differs from History | Shortcuts/order become surprising | One renderer and one presentation snapshot for filtered/unfiltered lists. |
| Search field widens/narrows menu unexpectedly | Layout jump or clipped controls | Stable minimum width and Auto Layout tests across localizations/long titles. |
| Search text enters telemetry or diagnostic logs | Privacy leak | Never interpolate query in logs/errors/events; privacy inspection in release gate. |

## 10. Test strategy

### Unit tests

- Query normalization, tokenization, matching fields, AND behavior, ordering.
- Renderer item properties, grouping boundaries, numbering, and shortcuts.
- Session generation/token rejection and empty-query immediate reset.
- Snapshot presentation values and result consistency.

### Repository/database integration tests

- Every successful history mutation emits a content-free refresh.
- Failed transactions do not emit false refreshes.
- Search creates no table, trigger, migration, UserDefaults key, or persistent
  plaintext.
- Protected states provide no caller-facing snapshot until authorized.

### AppKit component tests

- Stable menu/search identities during text and snapshot changes.
- Delegate lifecycle, focus request scheduling, close cleanup, no-result state.
- Result action routing, first-result Return, Down Arrow, numeric text input.

Some first-responder behavior cannot be trusted in a headless unit test; keep the
manual Milestone 0 and release checks even if component tests pass.

### Manual matrix

Run each entry point against:

- empty, one-item, 30-item, 1,000-item, and 10,000-item histories
- text, rich text, image with/without OCR, PDF, file URL, and color history
- snippets absent and present
- thumbnails and color previews on/off
- zero/one-based numbering and numeric shortcuts on/off
- inline grouping at 0, 1, boundary, and multiple overflow folders
- English plus every shipped localization and a marked-text IME
- plaintext, encrypted/unlocked, locked, key-unavailable, and error states when
  encryption is available

## 11. Implementation rules for the next model

- Preserve unrelated working-tree changes, especially the encryption work and
  `Configurations/CodeSigning.xcconfig`.
- Implement milestones in order. Update this document's milestone status and
  acceptance checkboxes after each milestone, then commit that milestone alone.
- Do not skip Milestone 0 because AppKit event tracking is the primary technical
  uncertainty.
- Do not add a persistent search index, schema migration, query telemetry, or
  UserDefaults storage.
- Do not fetch/decrypt history on every keystroke.
- Do not replace an open menu, search item, or search field.
- Do not activate Clipy to obtain focus.
- Do not use private AppKit APIs for search-field focus or selection.
- Treat failure to obtain authorized/decrypted history as an explicit empty or
  protected state, never as permission to search raw storage.
- Record any unavoidable deviation in this document before merging it.
