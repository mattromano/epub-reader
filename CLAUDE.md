# CLAUDE.md — Margins (personal iOS EPUB reader)

SwiftUI iPhone app for reading DRM-free EPUBs, capturing highlights, and tracking reading like an analytics pipeline:
- raw location events → sessions (fact) → daily and book aggregates.

The design is in `SPEC.md`, the milestones are in `PLAN.md`, and decisions plus per-milestone checks are in `OPEN_QUESTIONS.md`. **Read SPEC.md §5–§7 before touching persistence, tracking or highlights.**

## Stack (pinned)

- **iOS 27.0** deployment target (your iPhone is on iOS 27). Build with **Xcode 27.1** (Swift 6.4, iOS 27.1 SDK, needs macOS Tahoe 26.6+) ([Xcode 27.1 notes](https://developer.apple.com/tutorials/data/documentation/xcode-release-notes/xcode-27_1-release-notes.md)). Swift 6 language mode.
- **iOS 27 SDK rules**
  - Scene-based lifecycle is mandatory: apps built with the latest SDK that don't use scenes fail to launch. A SwiftUI `App` is fine; keep the Readium UIKit host inside it ([updates](https://developer.apple.com/documentation/updates.md), [iOS 27 notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes.md)).
  - `Info.plist` needs a `UILaunchScreen` entry, or App Store review rejects the build ([iOS 27 notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes.md)).
  - `@State` is a macro in Xcode 27: don't give it a default value and also assign it in `init()`, and don't stack it with other property wrappers ([WWDC26 session](https://developer.apple.com/videos/play/wwdc2026/269)).
  - Liquid Glass comes free with standard SwiftUI controls ([WWDC26 session](https://developer.apple.com/videos/play/wwdc2026/269)). Use system toolbars and sheets; don't hand-roll chrome backgrounds.
- **Readium Swift Toolkit 3.11.x** (`upToNextMinor(from: "3.11.0")`).
  - Products: `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`.
  - **Not** `ReadiumLCP`, `ReadiumOPDS` or `ReadiumAdapterGCDWebServer`.
  - Don't upgrade to 4.0 alphas.
- **GRDB 7.x** + **GRDBQuery** for SwiftUI `@Query`.
  - SQLiteData (Point-Free) is added only in the sync milestone (M8).
- **Swift Charts** for stats. No other UI dependencies. There are known iOS 27 bugs with `BarMark` time ranges in scrolling charts ([forum](https://developer.apple.com/forums/thread/835801)); if bars don't render, use `RectangleMark`.
- **XcodeGen:** `project.yml` is the source of truth. **Never hand-edit `.xcodeproj`**; edit `project.yml` and run `xcodegen generate`.

## Layout

```
project.yml
Margins/                     # app target (iOS only, may import UIKit + Readium)
  App/                       # MarginsApp, AppEnvironment (DI), scene phase handling
  Features/
    Library/                 # LibraryView, BookDetailSheet, ImportCoordinator
    Reader/                  # ReaderView (Representable), ReaderHostViewController,
                             # ReaderViewModel, PreferencesSheet, TOCSheet, SearchSheet,
                             # HighlightMenu, DecorationSync
    Quotes/                  # QuotesView, filters, ExportService, QuoteImageCard
    Stats/                   # StatsView + chart views
    Settings/
  ReadiumBridge/             # the ONLY place that converts Readium types <-> BookKit types
  Resources/                 # Assets, Info.plist fragments
Packages/BookKit/            # pure Swift, NO UIKit, NO Readium, builds + tests on macOS
  Sources/Persistence/       # AppDatabase, migrations, record structs, queries
  Sources/Importing/         # hashing, text normalizer, word indexer (input: XHTML strings)
  Sources/Tracking/          # SessionTracker state machine, TrackerEvent, Clock protocol
  Sources/Metrics/           # SQL for aggregates, streaks, pace, time-left; MetricsService
  Tests/...                  # one test target per module, plus Fixtures/
MarginsWidget/               # (M6) widget extension
TestBooks/                   # sample EPUBs (gitignored if copyrighted)
```

- **Module boundary rules**
  - BookKit never imports Readium.
  - Readium `Locator` values cross the boundary as `LocatorJSON` (a String) plus a small `AnchorHint` struct (href, progression, totalProgression, position, text before/highlight/after).
  - `ReadiumBridge/` does the conversion.
  - This keeps the logic that matters (DB, tracker, metrics, word math) testable with `swift test` in seconds, without a simulator.

## Commands

```bash
xcodegen generate                                   # after any project.yml change
swift test --package-path Packages/BookKit          # fast loop; run after every BookKit change
xcrun simctl list devices available | grep iPhone   # pick a simulator name
xcodebuild -project Margins.xcodeproj -scheme Margins \
  -destination 'platform=iOS Simulator,name=<iPhone name>' build
xcodebuild ... test                                  # app-level tests (fewer)
```

- **Until Xcode 27.1 is installed** (this Mac has Xcode 16.4 / iOS 18 SDK), the scheme command above can't find a destination. Build by target with an iOS 18 override and ad-hoc signing; ad-hoc signing is needed for the Files picker and the App Group to work in the simulator:
  ```bash
  xcodebuild -project Margins.xcodeproj -target Margins -sdk iphonesimulator -configuration Debug \
    IPHONEOS_DEPLOYMENT_TARGET=18.0 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    SYMROOT=$PWD/DerivedData/Build build
  ```
  Then install `DerivedData/Build/Debug-iphonesimulator/Margins.app` on a simulator. Test books: `python3 scripts/make_test_epubs.py TestBooks`.

- Device runs happen from Xcode (Cmd-R), signed with the Personal Team.
  - Free-tier installs expire after 7 days; just rebuild.
  - The app's data stays on the phone across the 7-day expiry, as long as the app isn't deleted.
  - Bundle ID `com.mattromano.margins`, App Group `group.com.mattromano.margins`. **Never change either one**: the app's data on the phone is tied to them.

## Data conventions (sync-ready from day one)

- **Tables:** `dim_*`, `fact_*`, `bridge_*`, `agg_*` (local rollups), `app_setting`. Columns are snake_case.
  - Swift record structs are camelCase, mapped with `CodingKeys` or GRDB column coding.
- **Synced tables** (see SPEC §5.2 ✓)
  - Exactly **one `TEXT` UUID primary key** (`<entity>_id`), and **no UNIQUE constraints besides the PK**. Dedupe in code. (SQLiteData sync requirement.)
  - Every column is nullable or has a DEFAULT.
  - Every row has `created_at`, `updated_at` and `deleted_at`. **Soft delete only**; queries filter `deleted_at IS NULL`.
  - This applies to `app_setting` too: `setting_id` UUID PK, `key` with a plain index, latest `updated_at` wins.
- **Facts are append-only.** `fact_reading_session` is written once at session end. Edits set `is_user_edited = 1` and bump `updated_at`.
- **Local-only, rebuildable:** `dim_chapter`, `dim_word_anchor`, `fact_location_event`, `session_draft`, `agg_*`. Never put user-entered data in these.
- **Time**
  - Timestamps are UTC ISO-8601 strings with milliseconds.
  - `local_date` (the reading day, using the day-start hour) is computed **in Swift at write time**. SQL never does timezone math.
- **Paths:** store **relative** paths (`Books/<sha>.epub`). Resolve them against the App Group container at runtime, because container paths change between installs.
- **Migrations:** GRDB `DatabaseMigrator`, named `vN_description`.
  - Never edit a migration once it has run on the phone; add a new one.
  - After M8, synced tables get additive changes only.
- **SQL style:** CTEs, not subqueries; bind parameters instead of scalar subqueries; one CTE per logical step; explicit column lists.
  - Metric SQL lives in `Metrics/SQL/*.sql` as resources, or as static strings in one file per metric, each with a doc comment naming the SPEC §6.3 metric it implements.

## Architecture notes

- **Database access**
  - One `AppDatabase` (a `DatabasePool` in the App Group container), injected through the SwiftUI environment.
  - Writes go through `AppDatabase` methods (`importBook`, `saveSession`, `saveHighlight`, …), never ad-hoc from views.
  - Reads in views use GRDBQuery `@Query` or `ValueObservation`.
- **Reader**
  - `EPUBNavigatorViewController` lives inside `ReaderHostViewController`, wrapped by a `UIViewControllerRepresentable`.
  - Use `navigator.addObserver(.tap{…})` for tap zones. **Don't attach SwiftUI gestures over the navigator** (Readium SwiftUI guide).
  - Custom selection-menu items are `EditingAction`s. They need the host view controller in the responder chain.
- **Highlights**
  - The DB is the source of truth.
  - Observe highlights for the current book, map them to `Decoration(id: highlight_id, locator:, style: .highlight(tint:))`, and call `apply(decorations:in: "highlights")` on the **main actor** with the full list every time.
  - Taps come back via `observeDecorationInteractions(inGroup:)`.
- **Anchors:** always store the full locator JSON **and** the normalized columns (quote_exact/prefix/suffix, char_start/char_end, chapter_text_hash, readium_version). See SPEC §7.
- **Tracking**
  - `SessionTracker` is a pure, deterministic state machine: `handle(_ event: TrackerEvent, at: Date) -> [TrackerOutput]`.
  - It takes a `Clock` and must not touch the DB, timers or UIKit.
  - The app layer feeds it location changes (with a `kind`: pageTurn / scroll / jump), scene-phase changes and a 30 s checkpoint tick.
  - Before calling `navigator.go(to:)` for a TOC, search, scrubber or highlight jump, set `pendingJump = true` so the next location change is classified as `jump`.
- **Word math:** never use Readium `position` or `totalProgression` for word counts; they're byte-based. Use `WordIndex` (SPEC §6.2).
- **Concurrency**
  - UI and navigator calls run on `@MainActor`.
  - Indexing runs in a detached `Task` with a low priority and writes in batches.
  - Never block the main thread on DB writes during page turns; GRDB async writes are fine.
- **Secrets:** the Readwise token is stored only in the Keychain. Never log it or write it to the DB.

## Testing

- **BookKit tests (Swift Testing `@Test`, or XCTest)**
  - Every migration runs against an in-memory DB.
  - Tracker: a scenario table of events → expected `active_seconds` / `words_read` / `end_reason`.
  - Word indexer: fixture XHTML → exact counts.
  - Metrics: **golden tests** on a seeded fixture DB with hand-computed expected values (pace = ratio of sums, SCD2 goals, streak through yesterday, time left).
  - Anchoring: quote → char range, ambiguity resolved by prefix, fuzzy re-anchor score threshold.
- **App tests:** keep them few. Import a fixture EPUB; launch the reader without crashing.
- **Workflow:** red → green. Add the failing test first for any metric or tracker bug.

## Do

- Run `swift test --package-path Packages/BookKit` before saying a BookKit change is done. Run the `xcodebuild` build before saying an app change is done.
- Read the relevant Readium guide before using an API. The guides live in the swift-toolkit repo, under `docs/Guides/` (Navigator, Decorations, Highlights, Preferences, Search, Content, SwiftUI, Open Publication).
- Keep each milestone's acceptance checklist (PLAN.md) in mind; tick items off in the PR or commit message.
- Use small commits with imperative subjects (`Add v3_sessions migration`).
- Handle malformed EPUBs with a user-facing error, never `try!` or `fatalError` on book content.

## Don't

- Don't edit `.xcodeproj` or `.pbxproj` directly.
- Don't add SwiftData, Core Data, Realm or other dependencies without updating SPEC.md.
- Don't add UNIQUE constraints or composite primary keys to synced tables.
- Don't hard-delete user data (highlights, sessions, books) in code paths other than an explicit "erase" action.
- Don't import UIKit or Readium in `Packages/BookKit`.
- Don't use Readium 4.0 alphas, `@_spi` experimental APIs, or the LCP module.
- Don't store absolute file paths, or keep security-scoped URLs open after import.
- Don't compute stats in Swift loops when SQL can do it. Aggregation belongs in `Metrics` SQL.
