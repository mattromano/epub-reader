# Margins — build plan

- Each milestone fits **one weekend session (about 3–4 hours)** unless it's marked ×2.
- Every milestone ends in a working app on your iPhone and a green `swift test`.
- The design decisions and schema live in [SPEC.md](SPEC.md). Conventions for Claude Code live in [CLAUDE.md](CLAUDE.md).

## Before you start (about 20 minutes, tonight or tomorrow morning)

- **Tools**
  - Install XcodeGen: `brew install xcodegen`.
  - Use **Xcode 27.1** (Oct 15, 2026; Swift 6.4, iOS 27.1 SDK). It needs macOS Tahoe 26.6 or later ([Xcode 27.1 notes](https://developer.apple.com/tutorials/data/documentation/xcode-release-notes/xcode-27_1-release-notes.md)).
  - Readium 3.11 (Swift 6.0+) and GRDB 7.12 (Swift 6.1+) meet this ([Readium README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md), [GRDB README](https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md)). Neither changelog mentions Xcode 27 yet, so M0 proves they build.
- **Phone**
  - Turn on Developer Mode: Settings › Privacy & Security › Developer Mode. It needs a restart and only appears after you've paired the phone with the Mac ([Apple](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device.md)).
- **Signing**
  - In Xcode › Settings › Accounts, add your Apple ID. The Personal Team is fine for Milestones 0–7.
- **Test books**
  - Put 5–6 DRM-free test books in a folder:
    - an EPUB 3 novel
    - an EPUB 2 book (Project Gutenberg offers both formats)
    - something long (> 300k words)
    - an image-heavy book
    - a fixed-layout book (picture book / comic)
    - one deliberately broken zip
  - Copy them into the iPhone Files app too.

## M0 — Skeleton: import and read a book (tomorrow)

- **Scope**
  - **Project setup**
    - XcodeGen `project.yml`: app target `Margins`, bundle ID `com.mattromano.margins`, iOS 27.0 deployment target, SwiftUI `App` (scene lifecycle is mandatory on the iOS 27 SDK), a `UILaunchScreen` entry in Info.plist, and the App Group capability `group.com.mattromano.margins`.
    - Local package `Packages/BookKit` with modules `Persistence`, `Tracking`, `Metrics` and `Importing`, each with a test target.
    - These modules must have **no UIKit or Readium imports**, so `swift test` runs on macOS.
  - **Dependencies (SPM)**
    - App: `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator` (3.11.x, `upToNextMinor`).
    - BookKit: `GRDB` 7.x. App: `GRDBQuery` (it imports SwiftUI, so it stays out of BookKit).
  - **Database**
    - `AppDatabase` with `DatabaseMigrator`, migration `v1_books` (the `dim_book` and `app_setting` tables from SPEC §5; `app_setting` is needed by M1's reader defaults).
    - The DB file is `AppGroup/Database/margins.sqlite`.
  - **Import**
    - `.fileImporter(allowedContentTypes: [.epub])`, using a security-scoped start/stop.
    - Copy to `AppGroup/Books/<sha256>.epub`.
    - Parse with Readium (`AssetRetriever` + `PublicationOpener`), insert `dim_book`, and extract the cover.
  - **Library screen:** a list of books with title, author, cover and last-opened date.
  - **Reader**
    - `ReaderHostViewController` wrapping `EPUBNavigatorViewController`, bridged with `UIViewControllerRepresentable` (follow Readium's [SwiftUI guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/SwiftUI.md)).
    - A close button, and tap zones through `navigator.addObserver(.tap{…})`.
  - **Resume:** save `last_locator_json` on location change (debounced to 2 s) and on close; reopen at that locator.
- **Acceptance**
  - [ ] Readium and GRDB resolve and build with Xcode 27.1; `xcodegen generate && xcodebuild … build` succeeds; the app runs on your iPhone (iOS 27) with the Personal Team.
  - [ ] You can import the EPUB 3 and EPUB 2 test books from Files; both appear in the library with covers.
  - [ ] Importing the same file twice doesn't create a duplicate row (content_hash check).
  - [ ] Opening a book, paging 10 pages, killing the app and reopening lands on the same page.
  - [ ] The broken zip shows an error alert, not a crash.
  - [ ] `swift test --package-path Packages/BookKit` is green (a migration test plus a dedupe test).
- **Stretch:** "Open in Margins" from the share sheet (`CFBundleDocumentTypes` + `onOpenURL`, copy-then-display).

## M1 — A real reader

- **Scope**
  - **Aa sheet:** font family, size, line height, margins, theme, scroll/paginated, publisher styles. It's a SwiftUI form over `PreferencesEditor` ([guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Preferences.md)).
  - **Per-book preferences** are saved in `preferences_json`; app-wide defaults go in `app_setting`.
  - **TOC sheet:** `publication.tableOfContents`, with a tap to `go(to:)`.
  - **Chrome:** toggle on center tap, with a progress scrubber.
  - **In-book search** ([guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Search.md)).
  - **Fixed-layout detection:** `layout = fixed` hides the Aa sheet.
  - Share-sheet "Open in", if not done in M0.
  - **Library:** sort options, search, status, and swipe to delete.
- **Acceptance**
  - [ ] Changing the font size or theme applies live and persists per book across relaunch.
  - [ ] Switching scroll ↔ paginated keeps the reading position.
  - [ ] TOC and search jump to the right place.
  - [ ] The fixed-layout test book opens without the Aa sheet.
  - [ ] A file shared from Files and from Mail ("Open in") imports correctly.

## M2 — Word index and session tracking (×2 sessions)

- **Session A: the word index**
  - Migration `v2_chapters_index`: `dim_chapter` and `dim_word_anchor`.
  - **Indexer** (in BookKit `Importing`):
    - Iterate the spine, strip XHTML to normalized text (collapse whitespace, decode entities), tokenize with `NLTokenizer(.word)`.
    - Write per-chapter `word_count` and `cum_words_start`, plus a block-level anchor every paragraph or 1–2k characters.
  - Run it as a background `Task` after import, and update `dim_book.word_count`. Version it with `index_version`.
  - `WordIndex.wordIdx(href:progression:)` interpolates between anchors.
  - **Tests:** a known fixture XHTML gives an exact word count; interpolation is monotonic; a non-linear spine item is excluded.
- **Session B: the tracker**
  - Migration `v3_sessions`: `fact_reading_session`, `fact_location_event`, `session_draft`, `dim_device`.
  - **`SessionTracker`**
    - A pure state machine (SPEC §6.1) that takes `TrackerEvent`s and a `Clock`.
    - It emits counted and uncounted location events and a finished session row.
  - **Reader wiring**
    - The Readium location-change callback → `TrackerEvent.locationChanged(kind:)`.
    - `kind` is `jump` when the change was caused by TOC, search, scrubber or a link. Set a flag before calling `go(to:)`.
    - `scenePhase` → pause and resume.
  - **Crash recovery:** checkpoint `session_draft` every 30 s and recover it on launch.
  - **Book detail sheet:** a session list (date, minutes, words, WPM) with swipe to delete.
- **Acceptance**
  - [ ] Unit tests: a scripted event sequence produces the expected `active_seconds` and `words_read`. Cover idle gaps, backgrounding, a TOC jump excluded, backwards paging counting 0 words, and a 20 s session discarded.
  - [ ] On device, read for 10 minutes with a timer. The logged session is within ±10% on minutes, and words is in a sane range (the WPM you'd expect, about 200–350).
  - [ ] Background the app for 10 minutes and resume: it's a new session. Under 5 minutes: the same session.
  - [ ] Force-kill mid-session, then relaunch: the session is recovered.
  - [ ] The long (300k+ word) book indexes without blocking the UI; the library shows "Indexing…" and then the word count.

## M3 — Highlights

- **Scope**
  - Migration `v4_highlights`: `fact_highlight`, `dim_tag`, `bridge_highlight_tag`, `fact_bookmark`.
  - **Selection menu:** custom `EditingAction`s for Highlight, Color, Note and Copy. Read `navigator.currentSelection`, then `clearSelection()` ([Highlights guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Highlights.md)).
  - **Capture the anchor (SPEC §7):** the full locator JSON, the quote/prefix/suffix, `char_start/char_end` in normalized text, and `chapter_text_hash`.
  - **Rendering**
    - Observe highlights for the open book with `ValueObservation`, then `apply(decorations:in: "highlights")` on the main actor.
    - Use `highlight_id` as the decoration id ([Decorations guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Decorations.md)).
  - **Tap a highlight** → a popover at `event.rect` to recolor, add a note, add tags, or delete.
  - **Book detail:** a highlights list; tap one to jump to its locator.
  - **Bookmarks:** a toolbar toggle and a list.
- **Acceptance**
  - [ ] You can create highlights in 5 colors; they persist across relaunch.
  - [ ] After changing the font size 3 steps, switching to scroll mode, and rotating the phone, every highlight still covers the same text.
  - [ ] Edit a note, add 2 tags, delete one highlight; the decorations update without reopening the book.
  - [ ] Unit test: the quote locator for a fixture chapter computes the correct `char_start`, with an ambiguous quote resolved by its prefix.
  - [ ] The two-tap rule holds: select text → Highlight creates it in the last-used color.

## M4 — Quotes view, search, export

- **Scope**
  - **Quotes tab:** a global list of all highlights, grouped by book or flat by date.
  - **Search:** an FTS5 table over quote, note, title and author; filter chips for book, color and tag.
  - **Exports** (written to a temp file and shared via `ShareLink` / `fileExporter`)
    - Markdown per book (Obsidian front matter + `[!quote]` callouts, SPEC §10).
    - CSV of all highlights.
  - **Quote-as-image:** a SwiftUI card → `ImageRenderer` → share. Use 2–3 themes.
  - **Re-anchor on open (SPEC §7, step 3):** compare `chapter_text_hash`, run an exact quote search with prefix/suffix scoring, and show an "unanchored" badge on orphans in the Quotes view. The fuzzy match is split out as M4.5.
- **Acceptance**
  - [ ] A search for a word returns matching highlights in under 100 ms with 1,000 seeded highlights (seed script in tests).
  - [ ] The Markdown export opens cleanly in Obsidian; the CSV opens in Numbers or Excel with correct columns and escaping.
  - [ ] The quote image renders legibly and shares to Messages.
  - [ ] Tapping a quote opens the reader at that highlight.

## M4.5 — Fuzzy re-anchor (half session)

- Use approximate quote matching with the Hypothesis weights (quote 50, prefix 20, suffix 20, position 2) and `maxErrors = min(256, len/2)` (SPEC §7).
- Accept a match at ≥ 0.75 of the max score; below that, mark the highlight `orphaned`.
- Rewrite the locator `text` and `progression`, then set `anchor_status` and `anchor_score`.
- **Acceptance**
  - [x] Unit test: a fixture chapter with a small edit near the quote re-anchors as `fuzzy`.
  - [x] A deleted passage becomes `orphaned`.

## M5 — Stats, goals, streaks (×2 sessions)

- **Session A: the metrics layer**
  - BookKit `Metrics`: SQL for `agg_daily_reading` and `agg_book_stats` (rebuildable, refreshed incrementally on session end), plus streaks (gaps-and-islands), pace and time-left (SPEC §6.3–6.4).
  - `dim_goal` (SCD2), with the migration seeding the default 30-minute daily goal (SPEC §5.2), plus the settings UI for goals, day-start hour and streak minimum.
  - **Golden tests:** a seeded fixture DB with hand-computed expected values for daily minutes, pace, current and longest streak, goal-met, and time left.
  - **Reader chrome:** "X min left in chapter · Y h Z m in book".
- **Session B: the dashboard**
  - Stats tab with Swift Charts (iOS 27 has known `BarMark` time-range bugs in scrolling charts; fall back to `RectangleMark` for the heatmap and session bars if needed — [forum](https://developer.apple.com/forums/thread/835801)):
    - today ring vs goal, streak cards
    - minutes per day (30/90/365)
    - WPM line with a rolling median
    - a weekday × hour heatmap
    - books finished per month/year
  - Per-book stats on the detail sheet.
  - "Rebuild stats" in Settings.
- **Acceptance**
  - [ ] All golden metric tests pass: a ratio of sums for pace, SCD2 goal changes applied mid-period, and the streak alive through yesterday.
  - [ ] The dashboard renders in under 300 ms with 2 years of synthetic sessions (about 1,500 rows).
  - [ ] "Time left in chapter" moves sensibly while reading (it decreases and doesn't jump around).
  - [ ] Finishing a book (marked finished) increments this year's count.

**MVP complete after M5.**

## M6 — Widgets (free tier is fine)

- Add a widget extension target sharing the App Group.
- The widget reads a small `widget_snapshot.json` written by the app on session end. This avoids DB locking from another process; GRDB on a shared file is possible but riskier.
- Families: systemSmall (streak + today ring), systemMedium (continue reading with cover + time left), accessoryRectangular (Lock Screen).
- `WidgetCenter.shared.reloadTimelines` after each session while the app is in the foreground ([doc](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date.md)).
- **Acceptance**
  - [ ] The widget updates within seconds of closing a book.
  - [ ] Tapping "continue reading" deep-links into the reader at the last locator.
  - [ ] Free-tier note: each extension uses another App ID (10 per 7 days). Watch that limit.

## M7 — Readwise push

- Store the token in the Keychain. Validate it with `GET /api/v2/auth/` (expect 204).
- `POST /api/v2/highlights/` in batches; use `highlight_url = margins://highlight/<uuid>` for idempotent updates. Respect 429 `Retry-After` ([api_deets](https://readwise.io/api_deets)).
- Track `export_readwise_at`; push new and changed highlights on demand, or on app background.
- **Acceptance**
  - [ ] Highlights appear in Readwise under the right book.
  - [ ] Re-running the push creates no duplicates; an edited note updates in Readwise.

## M8 — iCloud sync (needs the $99 Apple Developer Program) (×2–3 sessions)

- **Prerequisites**
  - Enroll in the Apple Developer Program; iCloud/CloudKit isn't available on the free tier ([capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)).
  - Moving the app from the Personal Team to the paid team may need a delete-and-reinstall, which would lose on-device data. This risk is accepted (OPEN_QUESTIONS #1). Check the current behavior right before you switch.
  - Add the iCloud (CloudKit) and Background Modes › Remote notifications capabilities.
- **Database sync**
  - Adopt SQLiteData's `SyncEngine` for synced tables only: `dim_book`, `fact_reading_session`, `fact_highlight`, `dim_tag`, `bridge_highlight_tag`, `fact_bookmark`, `dim_goal`, `dim_device`, `app_setting` ([README](https://raw.githubusercontent.com/pointfreeco/sqlite-data/main/README.md)).
  - Keep `dim_chapter`, `dim_word_anchor`, `fact_location_event` and the `agg_*` tables local.
  - Fallback: a hand-rolled `CKSyncEngine` ([doc](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5.md)).
- **Book files**
  - An iCloud Drive "Margins/Books" folder (`NSUbiquitousContainers`, public document scope).
  - On a second device, books whose metadata synced but whose file is missing show "Download" (`startDownloadingUbiquitousItem`).
- **Acceptance**
  - [ ] A highlight made on device A appears on device B within about a minute, with the app open on both.
  - [ ] Sessions from both devices roll up correctly in stats (via `dim_device`).
  - [ ] Delete and reinstall: everything restores. Expect it to be slow ([mjtsai](https://mjtsai.com/blog/2026/04/01/cksyncengine/)).

## M9 — TestFlight (optional)

- In App Store Connect, create the app record, upload a build from Xcode Organizer, and add internal testers (up to 100). External testers (up to 10,000) need beta app review ([TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)).
- Builds expire after 90 days (same source).
- Licensing check: Readium BSD-3 needs its notice in an Acknowledgements screen; GRDB and SQLiteData are MIT.

## Later backlog

- Migrate to Readium 4.0 once it's stable (Swift 6 `@MainActor` navigators, `Publication.timeline()`).
- Time-of-day v2: split sessions across hours using location events.
- Year in review; sessions CSV/Parquet export for your own dbt project; an on-device SQL console.
- TTS (`PublicationSpeechSynthesizer`), a share extension, iPad layout.
- iOS 27 App Intents: "Log reading session" and "Random quote" for Shortcuts and Siri ([App Intents updates](https://developer.apple.com/documentation/updates/appintents.md)).
- "Summarize my highlights" for a book with the iOS 27 Foundation Models `LanguageModel` API, on-device first ([WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)).
