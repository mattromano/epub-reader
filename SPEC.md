# Margins — personal iOS EPUB reader: spec

> Working name "Margins" (rename freely). Research verified 2026-11-22. Every technical claim carries its source URL inline; the full list is in [Sources](#11-sources). Items marked **(unverified)** were not confirmed against a primary source tonight.

## 0. TL;DR decisions

- **Rendering:** Readium Swift Toolkit **3.11.x** via SPM, wrapped in a `UIViewControllerRepresentable`. Don't use epub.js or foliate-js.
- **Fork vs build:** **build**, borrowing patterns from Readium's BSD-licensed TestApp. Don't fork Readest (AGPL, web stack).
- **Storage:** **GRDB 7 + raw SQL**, using a sync-ready schema from day one. Add **SQLiteData's `SyncEngine`** (Point-Free, CKSyncEngine-based) in the sync milestone. Not SwiftData: it has no GROUP BY or aggregates.
- **Database location:** the **App Group container** from Milestone 0, so the widget and a share extension can read it later without a migration. App Groups work on the free tier.
- **Highlight anchor:** the text quote (exact + prefix + suffix) is the primary anchor; Readium locator hints and our own character offsets are secondary. The full locator JSON is kept as well.
- **Word math:** our own import-time word index. Readium "positions" are 1024-byte chunks, not words.
- **Apple account:** start on the free Personal Team (7-day reinstall). Pay $99 before the iCloud sync milestone; CloudKit isn't available on the free tier. Switching teams may force a delete-and-reinstall that loses data from before M8. This risk is accepted (OPEN_QUESTIONS #1).
- **IDs:** bundle ID `com.mattromano.margins`, App Group `group.com.mattromano.margins`. Both are permanent.

---

## 1. Goals and non-goals

- **Goals**
  - Read DRM-free EPUB 2 and EPUB 3 books on iPhone, reflowable first.
  - Capture highlights and quotes in two taps: color, tags, note, a searchable global quotes view, and Markdown/CSV/Readwise export.
  - Analytics-grade reading tracking, modeled as raw events → sessions → daily aggregates, with explicit metric definitions.
  - Personal use first; keep a path to TestFlight.
- **Non-goals (v1)**
  - DRM / LCP. Readium's LCP module needs EDRLab's private `R2LCPClient.framework`, so leave out the `ReadiumLCP` product ([README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)).
  - PDF, CBZ, MOBI and audiobooks.
  - Media overlays (read-aloud audio synced to text). Readium lists them only as "planned" ([README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)).
  - A store, OPDS catalogs, or social features.
  - iPad layout (it should work, but isn't designed for).

## 2. Features: MVP vs later

### MVP (Milestones 0–5)

- **Library**
  - Import from Files (`.fileImporter`) and from "Open in…" / the share sheet (document types). The iCloud Drive folder comes later (paid account).
  - Covers, title, author, progress %, status (to read / reading / finished / abandoned).
  - Sort by recent, title, author or progress. Search by title or author.
  - Dedupe by file SHA-256.
- **Reader**
  - Paginated or scroll mode. Font, size, line height, margins, theme (light/sepia/dark), and publisher styles on/off.
  - Settings are saved per book, with app-wide defaults.
  - TOC, in-book search, a progress scrubber, and "time left in chapter / book" in the chrome.
  - Resume at the exact last location.
  - Fixed-layout books open read-only, with no typography settings and no WPM (see §9).
- **Highlights**
  - Select text → menu: Highlight (last-used color), color picker, Note, Tag, Copy, Share as image.
  - Five colors. Tap a highlight to edit, recolor or delete it.
  - Highlights survive font-size changes, mode switches and reopening.
- **Quotes view**
  - A global list of all highlights with full-text search (SQLite FTS5).
  - Filter by book, color, tag or date. Group by book.
- **Export**
  - Markdown per book (Obsidian-friendly) and CSV (all highlights).
  - Quote-as-image sharing with 2–3 themes.
- **Tracking**
  - Automatic sessions: start, end, active time, location, and words read. Idle and jump detection.
  - Session history per book, with manual delete or edit of bad sessions.
- **Stats dashboard**
  - Today vs goal, current and longest streak, minutes and words per day.
  - WPM trend, books finished per year, and a time-of-day heatmap.
  - Per-book stats.
- **Goals**
  - Daily minutes goal, and optionally a words goal and a yearly books goal.

### Later (Milestones 6+)

- Home screen and Lock Screen widgets: streak, today vs goal, "continue reading".
- Readwise API push (M7), then two-way sync (export API read-back).
- iCloud sync of the database across devices, and an optional iCloud Drive "Books" folder visible in Files.
- A share extension (only if "Open in" turns out to be insufficient).
- TTS through Readium's `PublicationSpeechSynthesizer` ([TTS guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/TTS.md)).
- Year-in-review page, CSV export of sessions (for your own SQL or dbt), and an on-device SQL console (fun, since you're a SQL person).
- TestFlight.

## 3. Screens and UX flows

- **Tab bar:** Library · Quotes · Stats · Settings. The reader is full-screen, presented over the tabs.
- **Library**
  - A grid or list toggle. Use a `+` button for importing, not a toolbar menu.
  - Empty state: "Import an EPUB from Files" button.
  - Long-press: book details, mark finished, delete (the file plus optionally its data).
- **Book detail sheet**
  - Metadata, progress, total time, average WPM, sessions list, highlights list, and an export button.
- **Reader**
  - **Tap zones** (use the navigator's tap observer, not SwiftUI gestures; see §5):
    - Left third → previous page
    - Right third → next page
    - Center → toggle chrome
  - **Chrome**
    - Top: back, title, TOC, search, Aa (settings).
    - Bottom: scrubber, "12 min left in chapter · 4 h 10 m in book", page or % indicator.
  - **Selection menu:** Highlight · Color · Note · Copy · Share image. Custom `EditingAction`s ([Highlights guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Highlights.md)).
  - **Highlight tap:** a popover anchored at `event.rect` with color swatches, note, tags, delete ([Decorations guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Decorations.md)).
  - **Aa sheet:** a SwiftUI form bound to Readium's `PreferencesEditor` ([Preferences guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Preferences.md)).
- **Quotes**
  - A search field (FTS) and filter chips (book, color, tag).
  - Cards show the quote, note, book, chapter and date.
  - Tap a card → open the reader at that highlight. Swipe → share or delete.
- **Stats**
  - Header cards: today's minutes vs goal (ring), current streak, this year's books.
  - Charts (Swift Charts): minutes per day (bar, 30/90/365 days), WPM trend (line with rolling median), time-of-day heatmap (weekday × hour), and books finished per month.
  - A per-book drilldown.
- **Settings**
  - Goals, day-start hour, idle threshold, export (Markdown / CSV / Readwise token stored in the Keychain), reader defaults, and "rebuild stats" (recomputes aggregates from facts).
- **Import flow**
  1. Receive the URL.
  2. `startAccessingSecurityScopedResource()`.
  3. Copy into `AppGroup/Books/<sha256>.epub`.
  4. `stop…`.
  5. Parse with Readium.
  6. Insert `dim_book`.
  7. Background task: build the word index (`dim_chapter`, `dim_word_anchor`).
  8. The book is readable immediately; time-left estimates appear once indexing finishes.

## 4. Tech stack and rationale

| Layer | Choice | Why |
|---|---|---|
| UI | SwiftUI, iOS 27.0 target, Xcode 27.1 / Swift 6.4 | Your phone runs iOS 27. `@Observable`, Swift Charts, Liquid Glass for free with system controls. |
| EPUB engine | Readium Swift Toolkit 3.11.x: `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator` | BSD-3, SPM, iOS 15+, actively released. Built-in highlights, locators, preferences, search, TTS. |
| DB | GRDB.swift 7.x (+ GRDBQuery for SwiftUI) | MIT, raw SQL/CTEs/window functions, migrations, observation. |
| Sync (later) | SQLiteData `SyncEngine` (Point-Free), or a hand-rolled CKSyncEngine | GRDB-based, CloudKit sync + sharing, MIT. |
| Charts | Swift Charts | First-party; no dependency. |
| Project | XcodeGen `project.yml` | Claude Code edits YAML far more safely than `.pbxproj`. The Readium TestApp uses XcodeGen too. |
| Tests | Swift Testing / XCTest; pure-Swift package tested with `swift test` on macOS | Fast loop with no simulator for the DB, tracker and metrics logic. |

### 4.1 Rendering: Readium vs alternatives

- **Readium Swift Toolkit — recommended**
  - **Releases**
    - Latest stable is 3.11.1 (2026-10-16), after 3.11.0 (2026-07-17) and 3.10.0 (2026-06-24) ([CHANGELOG](https://raw.githubusercontent.com/readium/swift-toolkit/main/CHANGELOG.md)).
    - 4.0.0-alpha.3 (2026-11-16) is on `develop`: Swift 6 strict concurrency, `@MainActor` navigators, and "API may still shift" ([develop CHANGELOG](https://raw.githubusercontent.com/readium/swift-toolkit/develop/CHANGELOG.md), [4.0 alpha.1 note](https://blog.readium.org/release-note-swift-toolkit-version-4-0-0-alpha-1/)).
    - **Pin to 3.11.x; migrate after 4.0 goes stable.**
  - **License and platforms:** BSD 3-Clause ([LICENSE](https://raw.githubusercontent.com/readium/swift-toolkit/main/LICENSE)). SPM recommended; Carthage dropped in 3.9.0 ([README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)). iOS 15.0 minimum; 3.8.0+ needs Swift 6.0 / Xcode 16.4 ([Package.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/Package.swift), [README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)).
  - **Format support**
    - Reflowable EPUB: pagination, scroll, RTL, search, highlights (Decorations) and TTS are all implemented.
    - Fixed-layout EPUB: everything except scroll mode ("want to do") ([README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)).
  - **UIKit only:** "The Navigator is built with UIKit". Wrap it in `UIViewControllerRepresentable` with a host `UIViewController` (the selection menu uses the responder chain). Use `navigator.addObserver(.tap{…})` instead of SwiftUI gestures, which block book interaction ([SwiftUI guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/SwiftUI.md)).
  - **Decorations**
    - `Decoration(id:locator:style:)` with `.highlight(tint:)` / `.underline`, in named groups.
    - `apply(decorations:in:)` diffs the whole group state. Taps arrive via `observeDecorationInteractions(inGroup:)` ([Decorations guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Decorations.md)).
    - Readium only renders. Persistence is the app's job: use the DB primary key as `Decoration.id` and re-apply on every DB change ([Highlights guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Highlights.md)).
  - **Experimental `Publication.timeline()` (4.0 alpha):** chapter / next / "left in chapter". EPUB places only the first TOC entry per resource ([Timeline guide](https://raw.githubusercontent.com/readium/swift-toolkit/develop/docs/Guides/Timeline.md)). Our own word index covers this on 3.x.
  - **Search:** `publication.search(query:)` returns a paged `SearchIterator` of `LocatorCollection`s; jump with `navigator.go(to:)` ([Search guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Search.md)).
  - **Fonts:** all iOS system fonts, plus bundled OpenDyslexic, AccessibleDfA and iA Writer Duospace. Font family can't change in fixed-layout books ([EPUB Fonts guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/EPUB%20Fonts.md)).
- **foliate-js in WKWebView — not recommended**
  - MIT, and supports more formats ([LICENSE](https://raw.githubusercontent.com/johnfactotum/foliate-js/main/LICENSE)).
  - The README says it's "*not* stable. Expect it to break and the API to change at any time"; there are no releases ([README](https://raw.githubusercontent.com/johnfactotum/foliate-js/main/README.md), [package.json](https://raw.githubusercontent.com/johnfactotum/foliate-js/main/package.json)).
  - You'd write the JS↔Swift bridge and the custom-scheme bundling yourself. WKWebView blocks ES modules on custom schemes, so you need an esbuild IIFE bundle ([vreader README](https://raw.githubusercontent.com/lllyys/vreader/main/README.md)).
- **epub.js — avoid**
  - Latest stable is 0.3.93 (2022-02-16); last publish was 0.5.0-alpha.3 (2023-09-26) ([npm registry](https://registry.npmjs.org/epubjs)).
- **Native Swift libraries — avoid**
  - FolioReaderKit is archived; last push was 2020 ([ecosyste.ms](https://awesome.ecosyste.ms/projects/github.com%2FFolioReader%2FFolioReaderKit)).
  - EPUBKit only parses, it doesn't render ([Swift Package Index](https://swiftpackageindex.com/witekbobrowski/EPUBKit)).

### 4.2 Fork vs build: **build on Readium**

- **Readest**
  - **License and stack:** AGPL-3.0 ([LICENSE](https://raw.githubusercontent.com/readest/readest/main/LICENSE)), built on Next.js 16 + Tauri v2 + foliate-js ([README](https://raw.githubusercontent.com/readest/readest/main/README.md), [package.json](https://raw.githubusercontent.com/readest/readest/main/apps/readest-app/package.json)).
  - **Activity:** very active (tag v0.12.20 on 2026-11-05). Its "Advanced Reading Stats" are still marked "Building" ([README](https://raw.githubusercontent.com/readest/readest/main/README.md)).
  - **Why not fork it**
    - You'd write the analytics model inside a large TS/React/Rust codebase, not SwiftUI.
    - Shipping it on TestFlight means publishing your full source under AGPL.
- **Readium TestApp** (in the swift-toolkit repo, BSD-3)
  - Includes a library, highlights (`HighlightContextMenu.swift`), bookmarks, search, TTS and a preferences UI. It's GRDB-backed and generated with XcodeGen ([TestApp README](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/README.md), [project.yml](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/Integrations/SPM/project.yml)).
  - It's a UIKit-heavy demo, so **copy patterns** from it (DB schema, highlight menu, search view model, preferences UI) rather than forking the app.
- **Thorium iOS**
  - On the App Store ([App Store](https://apps.apple.com/app/id6745025189)), but no public iOS source was found.
- **VReader, EPUBReaderSwiftUI**
  - Swift + Readium proofs of concept with **no LICENSE file** ([vreader](https://github.com/lllyys/vreader), [epubreaderswiftui](https://github.com/jtcodes/epubreaderswiftui)).
  - Read them for ideas; don't copy code.
- **Verdict**
  - None of these has your session fact table, WPM, streaks or goals, so you'd write that code either way.
  - Readium gives you the hard part (rendering and anchoring) as a library.

### 4.3 Storage: GRDB (+ SQLiteData later) vs SwiftData

- **SwiftData — rejected**
  - No GROUP BY / SUM / AVG; Apple's reply to a June 2026 request was "please file Feedback" ([forum](https://developer.apple.com/forums/thread/832186), [perf write-up](https://blakecrosley.com/blog/swiftdata-performance-storage-engine)).
  - **CloudKit sync constraints** ([Apple doc](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices.md)):
    - It syncs via `NSPersistentCloudKitContainer`.
    - `.unique` can't be enforced.
    - All relationships must be optional, and there is no `.deny` delete rule.
    - The schema is additive-only once in production.
    - Private database only: `CloudKitDatabase` is `.automatic`, `.private`, or `.none` ([doc](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct.md)).
  - An iOS 26 sync `BAD_REQUEST` report is still unresolved ([forum](https://developer.apple.com/forums/thread/811675)).
  - **Rechecked for iOS 27 (Nov 22):** iOS 27 adds `sectionBy` queries, `.codable`, `ResultsObserver` and `HistoryObserver`, but still no aggregates or GROUP BY ([SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata.md), [mjtsai](https://mjtsai.com/blog/2026/06/23/swiftdata-in-appleos-27/)). The recommendation stands.
- **GRDB — chosen**
  - 7.12.0 (2026-11-01), MIT, iOS 13+, Swift 6.1+ ([CHANGELOG](https://raw.githubusercontent.com/groue/GRDB.swift/master/CHANGELOG.md), [LICENSE](https://raw.githubusercontent.com/groue/GRDB.swift/master/LICENSE), [README](https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md)).
  - `DatabaseMigrator`, `ValueObservation` (async sequences), raw SQL and SQL interpolation ([README](https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md)).
  - GRDBQuery 0.11.0 provides SwiftUI `@Query` ([repo](https://github.com/groue/GRDBQuery)).
  - Window functions need SQLite ≥ 3.25 ([sqlite.org](https://www.sqlite.org/windowfunctions.html)). iOS has shipped ≥ 3.28 since iOS 13 ([The Apple Wiki](https://theapplewiki.com/wiki/Databases)).
    - The exact SQLite version in iOS 27 is **(unverified)**. Add a startup assertion on `sqlite_version()`.
  - The Readium TestApp itself uses GRDB ([project.yml](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/Integrations/SPM/project.yml)).
- **SQLiteData — the sync milestone**
  - "A fast, lightweight replacement for SwiftData, powered by SQL and supporting CloudKit synchronization" (and sharing). Built on GRDB, MIT ([README](https://raw.githubusercontent.com/pointfreeco/sqlite-data/main/README.md)).
  - 1.13.0 is about 12 days old ([Swift Package Index](https://swiftpackageindex.com/pointfreeco/sqlite-data)). 1.0 shipped 2025-09-18 ([Swift Forums](https://forums.swift.org/t/sqlitedata-1-0-an-alternative-to-swiftdata-with-cloudkit-sync-and-sharing/82211)).
  - **Its sync rules shape our schema now:** exactly one non-compound primary key per synced table, and no UNIQUE constraints other than the PK ([docs](https://docsearch.algolia.com/mcp/docs/repo/pointfreeco/sqlite-data)).
- **CKSyncEngine — the DIY alternative**
  - iOS 17+. You persist the engine state, register pending changes, handle `serverRecordChanged` conflicts, and work within 250 records per batch ([Apple doc](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5.md), [sample](https://github.com/apple/sample-cloudkit-sync-engine)).
  - Practitioner warnings: slow restore on fresh installs and replayed deletions ([mjtsai](https://mjtsai.com/blog/2026/04/01/cksyncengine/)).
- **Sync-ready schema rules (apply from Milestone 0)**
  - Every table has a single `TEXT` UUID primary key.
  - No other UNIQUE constraints. Dedupe in code: `dim_book.content_hash` gets a plain index, not a unique one.
  - Every column is nullable or has a default.
  - Every synced row has `created_at`, `updated_at` and `deleted_at` (soft delete).
  - Facts are append-only; edits are rare and done in the app, so sync conflicts are basically impossible.
  - Derived `agg_*` tables and the word index are **local-only and rebuildable**, and never synced.
- **Book files**
  - MVP: the app container, specifically the App Group container: `Books/<sha256>.epub`.
  - Later: an optional iCloud ubiquity "Books" folder.
    - Call `url(forUbiquityContainerIdentifier:)` off the main thread; it returns nil without iCloud ([doc](https://developer.apple.com/documentation/foundation/filemanager/url(forubiquitycontaineridentifier:).md)).
    - Files may be cloud-only stubs that need `startDownloadingUbiquitousItem(at:)` ([doc](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:).md)).

## 5. Data model

### Conventions

- **Naming:** snake_case. Prefixes `dim_` / `fact_` / `bridge_` / `agg_`.
- **Timestamps** are UTC ISO-8601 text (`2026-11-22T07:41:11.123Z`).
- **Local date** is precomputed at write time as `local_date` (`YYYY-MM-DD`), using the day-start hour (default 04:00). It's a reading-day, not a calendar day, so SQL never does timezone math.
- **Changing the day-start hour** applies only to sessions written after the change. Past sessions keep their stored `local_date`, so facts stay append-only. "Rebuild stats" only rebuilds the `agg_*` tables.
  - If you ever want history re-bucketed, add an explicit one-off action. `local_date` can be recomputed in Swift from `started_at` and `tz_offset_minutes`.
- **Sync scope:** a ✓ means the table syncs. A **local** table is rebuildable from synced tables plus the book file.

### 5.1 Grain overview

```
dim_book ─┬─< dim_chapter ─< dim_word_anchor          (local, rebuildable from file)
          ├─< fact_location_event >─ fact_reading_session   (events local; sessions ✓)
          ├─< fact_highlight ─< bridge_highlight_tag >─ dim_tag
          └─< fact_bookmark
dim_goal (SCD2)      agg_daily_reading / agg_book_stats   (local, rebuildable)
dim_device ✓
```

### 5.2 Tables

**`dim_book`** ✓ — one row per imported file

| column | type | notes |
|---|---|---|
| book_id | TEXT PK | UUID |
| content_hash | TEXT NOT NULL DEFAULT '' | sha256 of the file. Indexed, not unique; dedupe on import |
| identifier | TEXT | OPF `dc:identifier` (can be missing or garbage in EPUB 2) |
| title | TEXT DEFAULT '' | |
| authors | TEXT DEFAULT '' | display string. Authors in JSON go in `authors_json` |
| authors_json | TEXT DEFAULT '[]' | |
| language | TEXT | |
| publisher | TEXT | |
| published_date | TEXT | |
| epub_version | TEXT | '2.0' / '3.0' |
| layout | TEXT DEFAULT 'reflowable' | 'reflowable' or 'fixed' (`rendition:layout pre-paginated`) |
| reading_progression | TEXT DEFAULT 'ltr' | 'ltr' / 'rtl' |
| file_relpath | TEXT | relative to the container root (never store absolute paths; container paths change) |
| file_size_bytes | INTEGER DEFAULT 0 | |
| cover_relpath | TEXT | |
| word_count | INTEGER | null until indexed |
| chapter_count | INTEGER | |
| index_version | INTEGER DEFAULT 0 | bumped when the word-index algorithm changes → triggers a re-index |
| status | TEXT DEFAULT 'to_read' | to_read / reading / finished / abandoned |
| rating | INTEGER | 1–5 |
| started_at | TEXT | first session |
| finished_at | TEXT | set when marked finished, or when progress ≥ 0.99 plus a prompt |
| last_locator_json | TEXT | resume point (full Readium Locator JSON) |
| last_total_progression | REAL DEFAULT 0 | |
| last_opened_at | TEXT | |
| preferences_json | TEXT DEFAULT '{}' | serialized `EPUBPreferences` |
| created_at / updated_at / deleted_at | TEXT | |

**`dim_chapter`** local — one row per spine item

| column | type | notes |
|---|---|---|
| chapter_id | TEXT PK | `<book_id>:<spine_index>`. Deterministic, so a re-index keeps `fact_highlight.chapter_id` valid |
| book_id | TEXT FK → dim_book ON DELETE CASCADE | |
| spine_index | INTEGER | |
| href | TEXT | normalized Readium href |
| title | TEXT | from the TOC (nav, falling back to NCX), or 'Section N' |
| is_linear | INTEGER DEFAULT 1 | `linear="no"` items are excluded from book totals |
| word_count | INTEGER DEFAULT 0 | |
| char_count | INTEGER DEFAULT 0 | normalized plain-text length |
| cum_words_start | INTEGER DEFAULT 0 | words before this chapter (linear only) |
| text_hash | TEXT | sha256 of the normalized chapter text (detects content change) |

**`dim_word_anchor`** local — progression → word-offset lookup, one row per text block (paragraph-ish)

| column | type | notes |
|---|---|---|
| anchor_id | TEXT PK | |
| book_id | TEXT FK | |
| chapter_id | TEXT FK | |
| block_index | INTEGER | order within the chapter |
| progression | REAL | the block's start progression within the resource (0–1) |
| char_offset | INTEGER | normalized char offset of block start |
| cum_word_offset | INTEGER | words before this block, within the chapter |

- **Unique index:** `(chapter_id, block_index)`. This is fine because the table is local and never synced.
- **Lookup:** `word_idx(locator)` = `dim_chapter.cum_words_start` + an interpolation of `cum_word_offset` between the two anchors around `locator.locations.progression`.

**`fact_location_event`** local (optionally exportable) — raw grain: one row per navigator location change

| column | type | notes |
|---|---|---|
| event_id | TEXT PK | |
| session_id | TEXT FK | |
| book_id | TEXT FK | |
| occurred_at | TEXT | UTC |
| event_type | TEXT | `page_turn` · `scroll` · `jump` (TOC, search, link, scrubber, highlight tap) · `open` · `close` · `pause` · `resume` |
| chapter_id | TEXT | |
| progression | REAL | |
| total_progression | REAL | |
| word_idx | INTEGER | from `dim_word_anchor` (null if not indexed yet; backfill when indexed) |
| words_delta | INTEGER | `word_idx − prev word_idx` within the session |
| seconds_since_prev | REAL | |
| is_counted | INTEGER | 1 if it contributes to words_read (see §6) |
| locator_json | TEXT | |

- Scroll mode emits throttled location changes: at most one per 2 s, and at most one per 0.5% of progression change.

**`fact_reading_session`** ✓ — one row per continuous reading session (written at session end, immutable after)

| column | type | notes |
|---|---|---|
| session_id | TEXT PK | |
| book_id | TEXT FK | |
| device_id | TEXT FK → dim_device | |
| started_at / ended_at | TEXT | UTC, wall-clock |
| local_date | TEXT | reading-day of `started_at` |
| local_start_hour | INTEGER | 0–23, for time-of-day analysis |
| tz_offset_minutes | INTEGER | at session start |
| wall_seconds | REAL | ended − started |
| active_seconds | REAL | wall minus idle gaps (§6) |
| start_word_idx / end_word_idx | INTEGER | |
| words_read | INTEGER DEFAULT 0 | sum of counted forward deltas (§6) |
| start_total_progression / end_total_progression | REAL | |
| start_locator_json / end_locator_json | TEXT | |
| page_turns | INTEGER DEFAULT 0 | |
| jump_count | INTEGER DEFAULT 0 | |
| reading_mode | TEXT | 'paginated' / 'scroll' |
| font_size | REAL | snapshot, for pace-vs-settings analysis |
| end_reason | TEXT | closed / backgrounded / idle_timeout / book_switched / crash_recovered |
| is_pace_eligible | INTEGER DEFAULT 1 | 0 if fixed layout, unindexed, or active_seconds < 60 or words_read < 50 |
| is_user_edited | INTEGER DEFAULT 0 | |
| created_at / updated_at / deleted_at | TEXT | |

- Index on `(book_id, started_at)` and on `(local_date)`.
- **In-progress session:** keep it in memory, and checkpoint a `session_draft` row every 30 s to a local table. On crash or kill, launch recovers it as `end_reason = 'crash_recovered'`, ending at the last checkpoint.

**`session_draft`** local — at most one row per in-progress session; deleted when the session is written to `fact_reading_session`

| column | type | notes |
|---|---|---|
| session_id | TEXT PK | becomes the `fact_reading_session.session_id` |
| book_id | TEXT | |
| started_at | TEXT | UTC |
| last_checkpoint_at | TEXT | UTC; the recovered session ends here |
| state_json | TEXT | serialized `SessionTracker` state (running totals, last event, baseline word_idx) |

**`fact_highlight`** ✓ — one row per highlight. Anchor design is in §7.

| column | type | notes |
|---|---|---|
| highlight_id | TEXT PK | also the Readium `Decoration.id` |
| book_id | TEXT FK | |
| chapter_id | TEXT | |
| spine_href | TEXT | |
| chapter_title | TEXT | snapshot |
| quote_exact | TEXT NOT NULL DEFAULT '' | the selected text, sanitized |
| quote_prefix / quote_suffix | TEXT DEFAULT '' | about 32–64 characters of context |
| char_start / char_end | INTEGER | in the normalized chapter text (our normalizer) |
| word_idx | INTEGER | book-level word index at start (for sorting and density) |
| word_count | INTEGER | |
| progression / total_progression | REAL | |
| position | INTEGER | Readium position |
| css_selector / partial_cfi / dom_range_json | TEXT | Readium hints (nullable) |
| locator_json | TEXT | full Readium locator |
| readium_version | TEXT | locator format has changed before (v3 href change) |
| chapter_text_hash | TEXT | at capture time |
| anchor_status | TEXT DEFAULT 'exact' | exact / fuzzy / orphaned |
| anchor_score | REAL | |
| last_anchored_at | TEXT | |
| color | TEXT DEFAULT 'yellow' | yellow / green / blue / pink / purple |
| note | TEXT DEFAULT '' | |
| style | TEXT DEFAULT 'highlight' | highlight / underline |
| export_readwise_at | TEXT | last successful push |
| created_at / updated_at / deleted_at | TEXT | |

- Index on `(book_id, total_progression)`. Also create an FTS5 virtual table `fts_highlight(quote_exact, note, title, authors)`, kept in sync with triggers or GRDB FTS5 sync. GRDB's FTS5 support is **(unverified tonight)**; it's in GRDB's full-text-search docs.

**`dim_tag`** ✓: `tag_id` PK, `name`, `color`, plus the timestamp columns.
- Case-insensitive name dedupe happens in code, not with a UNIQUE constraint.

**`bridge_highlight_tag`** ✓: `bridge_id` PK (UUID), `highlight_id` FK, `tag_id` FK, plus timestamps.
- A single-column PK is required for SQLiteData sync. Make `(highlight_id, tag_id)` a non-unique index and dedupe in code.

**`fact_bookmark`** ✓: `bookmark_id`, `book_id`, `locator_json`, `total_progression`, `label`, plus timestamps.

**`dim_goal`** ✓ — SCD type 2, so past days are judged against the goal that was in effect then

| column | type | notes |
|---|---|---|
| goal_id | TEXT PK | |
| metric | TEXT | daily_minutes / daily_words / yearly_books |
| target | REAL | |
| valid_from | TEXT | local_date, inclusive |
| valid_to | TEXT | local_date, exclusive; null = current |
| timestamps | | |

**`dim_device`** ✓: `device_id` PK, `name`, `model`, `first_seen_at`, plus timestamps.

**`app_setting`** ✓: `setting_id` TEXT PK (UUID), `key` TEXT DEFAULT '', `value_json` TEXT DEFAULT 'null', plus the timestamp columns.
- `key` gets a plain (non-unique) index. Dedupe in code: the latest `updated_at` wins. This follows the synced-table rules (one UUID PK and no other UNIQUE constraint).
- Keys and defaults: `day_start_hour` = 4, `idle_threshold_s` = 180, `session_gap_s` = 300, `streak_min_minutes` = 5, `default_preferences`.
- The daily-minutes goal (default 30) lives in `dim_goal`, not here. The M5 migration that creates `dim_goal` seeds one `daily_minutes` row: target 30, `valid_from` = the earliest session `local_date` (or today if there are none), `valid_to` null.
- Created in the M0 migration `v1_books` alongside `dim_book`, because M1 stores reader defaults here.
- The Readwise token goes in the **Keychain**, never in the DB.

**Local aggregates (rebuildable)**
- `agg_daily_reading`
  - `local_date` PK, `active_minutes`, `words_read`, `sessions`, `books_touched`, `pace_wpm`
  - `goal_minutes`, `goal_met` (0/1), `highlights_created`
- `agg_book_stats`
  - `book_id` PK, `total_active_minutes`, `total_words_read`, `sessions`, `first_read_date`, `last_read_date`
  - `avg_wpm`, `median_session_minutes`, `highlights`, `pct_complete`
- Both are refreshed incrementally on session end (re-computing that date and that book). "Rebuild stats" recomputes everything.

### 5.3 Migrations

- GRDB `DatabaseMigrator`, with named migrations: `v1_books`, `v2_chapters_index`, `v3_sessions`, and so on.
- Never edit a shipped migration.
- Once sync is on (CloudKit), synced-table changes are **additive only**. This matches CloudKit's production-schema rule ([SwiftData sync doc](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices.md)).

## 6. Tracking logic and metric definitions

### 6.1 Session state machine

- **States and transitions**
  - `idle` → `reading` on book open.
  - `reading` → `paused` on app background, screen lock, or no location event for `idle_threshold_s`.
  - `paused` → `reading` on foreground or interaction within `session_gap_s`.
  - `paused` → `ended` after `session_gap_s`.
  - `reading` → `ended` on book close or a switch to another book.
- **Defaults**
  - `idle_threshold_s` = **180** (a long page can take more than 2 minutes).
  - `session_gap_s` = **300**: resuming within 5 minutes continues the same session.
  - Both are configurable.
- **Active time**
  - Sum of the gaps between consecutive events, each capped at `idle_threshold_s`.
  - Plus a tail of min(time since last event, median page time) at pause or end.
  - Background time is excluded.
- **Discard rule:** a session is dropped unless `active_seconds ≥ 30` **and** there is at least one page_turn or scroll event.
- **The tracker is a pure Swift type.** It takes `(event, timestamp)` and returns `(state, emitted rows)`, so it can be unit-tested with a fake clock.

### 6.2 Counting words

- `words_delta = word_idx − prev_word_idx`.
- An event is **counted** (`is_counted = 1`) when all of these hold:
  - it's a `page_turn` or `scroll`;
  - `0 < words_delta ≤ max(1500, 5 × p95_page_words)`;
  - the implied rate `words_delta / seconds_since_prev` is ≤ **1500 WPM**.
- **Backwards moves** count 0 words but still count toward active time (re-reading is reading).
- **Jumps** (TOC, search, link, scrubber, or a forward delta above the cap) count 0 words and reset the baseline.
- `words_read` (session) = Σ `words_delta` where `is_counted = 1`.
- **Why our own index:** Readium positions are "archive entry length split by 1024 bytes" (compressed size for deflated entries), which is not proportional to words ([EPUBPositionsService.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/Sources/Streamer/Parser/EPUB/Services/EPUBPositionsService.swift)).
  - Readium's Content API (`publication.content(from:)`) is experimental, and `text()` is "an expensive operation… cache the result" ([Content guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Content.md)).
  - So index once at import, in the background, with a versioned algorithm.
- **Tokenizer:** `NLTokenizer(unit: .word)` for language-correct counts (CJK included). **(unverified tonight)** Apple NaturalLanguage API.
  - The same normalizer produces `char_start` for highlights.

### 6.3 Metric definitions

| metric | definition | notes |
|---|---|---|
| **Active minutes** (day) | Σ `active_seconds`/60 of non-deleted sessions with `local_date = d` | the primary "time read" |
| **Words read** (day / book) | Σ `words_read` | forward, counted only |
| **Session WPM** | `words_read / (active_seconds/60)`, for pace-eligible sessions | displayed, not averaged naively |
| **Pace WPM** (period or book) | Σ words_read / Σ active_minutes over pace-eligible sessions | a ratio of sums, not an average of ratios |
| **Rolling pace** | pace over the last 14 days of eligible sessions; requires ≥ 20 active minutes, otherwise use the 90-day window | used for estimates |
| **Book pace** | pace on this book, once it has ≥ 15 eligible minutes; otherwise rolling pace | genre and font differences |
| **Time left in chapter** | `(chapter.cum_words_start + chapter.word_count − current_word_idx) / book_pace` | shown when indexed and pace exists |
| **Time left in book** | `(book.word_count − current_word_idx) / book_pace` | linear chapters only |
| **% complete** | `current_word_idx / book.word_count` (fall back to Readium `totalProgression`) | words, not bytes |
| **Qualifying day** | a day with active minutes ≥ `streak_min_minutes` (default 5) | |
| **Current streak** | the length of the run of consecutive qualifying days ending today, or yesterday if today doesn't qualify yet | gaps-and-islands |
| **Longest streak** | the max run length ever | |
| **Daily goal met** | active minutes(d) ≥ the target from the `dim_goal` row valid on d | SCD2 join |
| **Goal hit rate** | goal-met days / days since the goal started | |
| **Books finished (year)** | count of `dim_book` with `finished_at` in that year (reading-day) and status = finished | yearly goal progress |
| **Time-of-day profile** | Σ active minutes by `local_start_hour` (and weekday) | v1 attributes the whole session to its start hour; v2 splits by events |
| **Avg session length** | median `active_seconds` per period | median resists outliers |
| **Highlight density** | highlights per 10k words read, per book | fun "how much did I love it" metric |

### 6.4 Reference SQL (SQLite, CTE style)

```sql
-- Daily rollup with SCD2 goal join
WITH sessions AS (
  SELECT local_date, active_seconds, words_read, is_pace_eligible, book_id
  FROM fact_reading_session
  WHERE deleted_at IS NULL
),
daily AS (
  SELECT local_date,
         SUM(active_seconds) / 60.0                         AS active_minutes,
         SUM(words_read)                                    AS words_read,
         COUNT(*)                                           AS sessions,
         COUNT(DISTINCT book_id)                            AS books_touched,
         SUM(CASE WHEN is_pace_eligible = 1 THEN words_read END) * 60.0
           / NULLIF(SUM(CASE WHEN is_pace_eligible = 1 THEN active_seconds END), 0) AS pace_wpm
  FROM sessions
  GROUP BY local_date
),
goals AS (
  SELECT target, valid_from, COALESCE(valid_to, '9999-12-31') AS valid_to
  FROM dim_goal
  WHERE metric = 'daily_minutes' AND deleted_at IS NULL
)
SELECT d.*, g.target AS goal_minutes,
       CASE WHEN d.active_minutes >= g.target THEN 1 ELSE 0 END AS goal_met
FROM daily AS d
LEFT JOIN goals AS g
  ON d.local_date >= g.valid_from AND d.local_date < g.valid_to;
```

```sql
-- Streaks: gaps-and-islands over qualifying days
WITH qualifying AS (
  SELECT local_date
  FROM agg_daily_reading
  WHERE active_minutes >= :min_minutes   -- bound from app_setting.streak_min_minutes in Swift
),
islands AS (
  SELECT local_date,
         julianday(local_date) - ROW_NUMBER() OVER (ORDER BY local_date) AS grp
  FROM qualifying
),
runs AS (
  SELECT MIN(local_date) AS run_start, MAX(local_date) AS run_end, COUNT(*) AS run_days
  FROM islands
  GROUP BY grp
)
SELECT run_start, run_end, run_days
FROM runs
ORDER BY run_end DESC;
-- current streak = first row's run_days if run_end IN (today, yesterday) else 0
-- longest streak = MAX(run_days)
```


## 7. Highlight anchoring (survives re-pagination and font changes)

- **How Readium re-anchors**
  - If `text.highlight` exists, it runs Hypothesis's `TextQuoteAnchor` with prefix = `before` and suffix = `after`. The search is scoped to the `cssSelector` element, falling back to `body`.
  - Otherwise it uses `cssSelector` or the fragment.
  - It never reads `domRange` ([utils.js](https://raw.githubusercontent.com/readium/swift-toolkit/main/Sources/Navigator/EPUB/Scripts/src/utils.js)).
  - **Implication:** the text quote is the real anchor. Pagination and font size don't affect it, because they don't change the DOM text.
- **Locator fields we keep**
  - `href`, `progression`, `totalProgression`, `position`, `text.before/highlight/after` ([Locator model](https://readium.org/architecture/models/locators/)).
  - HTML extensions: `cssSelector`, `partialCfi`, `domRange` ([HTML extension](https://readium.org/architecture/models/locators/extensions/html.html)).
- **Our scheme** (W3C Web Annotation style: TextQuote is primary, TextPosition is the hint, Css/Range are refinements; [annotation model](https://www.w3.org/TR/annotation-model/))
  1. **Capture**
     - From `navigator.currentSelection.locator`, store the full JSON plus `quote_exact/prefix/suffix` from `locator.text.sanitized()` ([Locator.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/Sources/Shared/Publication/Locator.swift)).
     - Compute `char_start/char_end` by finding the quote in our normalized chapter text, with the prefix and suffix as disambiguation. Store `chapter_text_hash`.
  2. **Render:** pass the stored locator to `Decoration`. Readium's quote anchoring handles font, size and mode changes.
  3. **Verify on open**
     - If `chapter_text_hash` differs from the current file's (the book file was replaced or updated), re-anchor in Swift.
     - Try an exact search for `quote_exact` with prefix/suffix scoring.
     - Otherwise fall back to a fuzzy match (approx string match). Use the Hypothesis weights — quote 50 / prefix 20 / suffix 20 / position hint 2 — with `maxErrors = min(256, len/2)` ([match-quote.ts](https://raw.githubusercontent.com/hypothesis/client/main/src/annotator/anchoring/match-quote.ts), [Hypothesis blog](https://web.hypothes.is/blog/fuzzy-anchoring/)).
     - Hypothesis has no enforced minimum score, so **add a threshold** (for example ≥ 0.75 of the max). Below it, mark the highlight `orphaned`.
     - Rewrite the locator `text` and `progression` for the new position and set `anchor_status`.
  4. **Orphans** stay visible in the Quotes view with an "unanchored" badge. They're never deleted automatically.
- **Format churn:** Readium 3.0 changed the href format and needed `Locator(legacyJSONString:)` migrations ([Migration Guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Migration%20Guide.md)). 4.0 changes `fragments` to `[URLFragment]` but still reads old locators ([develop CHANGELOG](https://raw.githubusercontent.com/readium/swift-toolkit/develop/CHANGELOG.md)). That's why we keep normalized columns plus `readium_version`.
- **EPUB CFI:** not our primary anchor. CFIs break when the DOM changes unless their text assertions can recover them ([EPUB CFI](https://w3c.github.io/epub-specs/epub33/epubcfi/)). Store `partial_cfi` only as a hint.

## 8. Import, files and platform setup

- **File type:** `UTType.epub` = `org.idpf.epub-container` (iOS 14+) ([doc](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/epub.md)). It's system-declared, so no import declaration is needed (inference).
- **Info.plist**
  - `CFBundleDocumentTypes` with `LSItemContentTypes = [org.idpf.epub-container]` and `LSHandlerRank = Alternate`. This makes the app show up in "Open in…" and the share sheet ([doc](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes.md)).
  - `LSSupportsOpeningDocumentsInPlace = NO`, because we always copy ([doc](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace.md)).
- **Incoming files**
  - `.fileImporter` returns security-scoped URLs. Balance every `startAccessingSecurityScopedResource()` with a `stop…`, because leaks exhaust kernel resources ([fileImporter](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:).md), [startAccessing…](https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource().md)).
  - "Open in" arrives through `onOpenURL` ([doc](https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:).md)).
  - **Copy, then display**, inside `NSFileCoordinator`. This is an Apple engineer's advice ([forum](https://developer.apple.com/forums/thread/756307)).
  - Don't rely on `Documents/Inbox`: one report says files shared on iPadOS 26 no longer land there ([forum](https://developer.apple.com/forums/thread/801090)).
- **Share extension:** skip it for the MVP; "Open in" covers the share sheet. If one is added later, use `NSExtensionActivationSupportsFileWithMaxCount` and hand files over through the App Group container ([activation rule](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/nsextensionactivationrule.md), [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups.md)).
- **iCloud Drive folder in Files (paid account)**
  - Set `NSUbiquitousContainers` → `NSUbiquitousContainerIsDocumentScopePublic = YES`. Files must go under `Documents/`.
  - The folder only appears after first use, and only after a `CFBundleVersion` bump.
  - Keep `CFBundleVersion` low and monotonic during debugging, because Apple remembers the highest one ([QA1893](https://developer.apple.com/library/archive/qa/qa1893/_index.html), [forum](https://developer.apple.com/forums/thread/774121)).
- **App Group:** `group.com.mattromano.margins` (bundle ID `com.mattromano.margins`). Up to 1,000 groups per account, and IDs must start with `group.` ([doc](https://developer.apple.com/documentation/xcode/configuring-app-groups.md)). Free tier is OK ([capabilities table](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)).
- **Widgets (later)**
  - Read the same SQLite file in the App Group read-only, or a small JSON snapshot.
  - Call `WidgetCenter.shared.reloadTimelines(ofKind:)` on session end while the app is in the foreground; foreground reloads don't count against the 40–70/day budget ([doc](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date.md)).
  - Interactive buttons need `AppIntent`s, iOS 17+ ([doc](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities.md)).
  - Lock Screen `accessoryRectangular` needs iOS 16+ ([doc](https://developer.apple.com/documentation/widgetkit/widgetfamily/accessoryrectangular.md)).

## 9. EPUB gotchas and handling

- **EPUB 2 vs 3**
  - EPUB 3 requires a XHTML nav document; NCX is legacy ([EPUB 3.3](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/core/index.html)). Reading systems MUST attempt pre-3.0 books ([RS spec](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/rs/index.html)).
  - The cover is `properties="cover-image"` in EPUB 3 and `<meta name="cover">` in EPUB 2.
  - Treat all metadata as optional.
  - Readium's parser handles both. Test with at least one EPUB 2 file.
- **Spec status:** EPUB 3.3 is a W3C Recommendation; the current edition is dated 2026-01-13 ([W3C](https://www.w3.org/TR/epub-33/)). The package version is still "3.0".
- **Fixed layout**
  - `rendition:layout = pre-paginated`. Reading systems "typically restrict or deny" user styles on these books ([EPUB 3.3](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/core/index.html)).
  - Readium supports them, but not scroll mode ([README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)). Two-page-spread decoration duplication is fixed only in 4.0 alpha.3 ([develop CHANGELOG](https://raw.githubusercontent.com/readium/swift-toolkit/develop/CHANGELOG.md)).
  - **Policy:** fixed-layout books open, the Aa sheet is hidden, `is_pace_eligible = 0`, and time is tracked but words aren't.
- **RTL / vertical:** `page-progression-direction` on the spine. Readium supports RTL ([README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)). Store it in `dim_book.reading_progression`.
- **Obfuscated fonts:** IDPF XOR of the first 1040 bytes, declared in `META-INF/encryption.xml` ([EPUB 3.3](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/core/index.html)). Without de-obfuscation, books fall back to system fonts.
  - Whether Readium de-obfuscates IDPF fonts is **(unverified)**; check with a test file.
- **Malformed books**
  - The `mimetype` file must come first and be uncompressed ([EPUB 3.3](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/core/index.html)). Real-world files often break this, so show a friendly error rather than crashing.
  - Keep a `TestBooks/` folder of awkward samples.
- **Large or image-heavy books**
  - Never load the whole book into memory. Readium streams resources.
  - Run the word index on a background task, one spine item at a time.
  - WebKit content processes can be killed under memory pressure ([doc](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:).md)). Checkpoint the last location every few seconds so a reload resumes in place.
- **Scripted EPUBs:** not supported. Readium's HTML runs in WKWebView; foliate-js documents WebKit sandbox limits for scripted content ([foliate-js README](https://raw.githubusercontent.com/johnfactotum/foliate-js/main/README.md)).
- **Accessibility**
  - Readium parses EPUB Accessibility metadata ([Readium a11y guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Accessibility.md); [EPUB A11y 1.1](https://www.w3.org/standards/history/epub-a11y-11/)). It bundles OpenDyslexic and AccessibleDfA ([fonts guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/EPUB%20Fonts.md)).
  - For our own chrome: VoiceOver labels on all controls, and Dynamic Type on SwiftUI screens.
  - Map the reader font size default to Dynamic Type. VoiceOver inside WKWebView content is **(unverified)**; test it.

## 10. Export formats

- **Markdown (one file per book, Obsidian-style)**
  - YAML front matter: `title`, `author`, `tags`, `date_finished` ([Obsidian properties](https://obsidian.md/help/properties)).
  - One callout per highlight, with the note and tags below ([Obsidian callouts](https://obsidian.md/help/callouts)):

    ```
    > [!quote] Chapter 3 · yellow
    > highlight text
    ```

- **CSV (all highlights)**
  - Columns: `highlight_id, book_title, author, chapter, quote, note, tags, color, total_progression, created_at`.
  - Readwise's own CSV import column spec couldn't be verified; its import page needs a sign-in ([docs](https://docs.readwise.io/readwise/docs/importing-highlights)). Use the API.
- **Readwise API** ([api_deets](https://readwise.io/api_deets))
  - Auth: `Authorization: Token XXX`. `GET /api/v2/auth/` returns 204 when the token is valid.
  - `POST /api/v2/highlights/` with `{"highlights":[{text, title, author, category:"books", note, location, location_type:"order", highlighted_at, highlight_url, source_type:"margins"}]}`.
  - Set `highlight_url` to `margins://highlight/<uuid>`, which is unique per highlight. Re-sending it updates the highlight's **text** only; Readwise dedupes on title/author/text/source_url, so a note-only change is ignored.
  - Edits (text, note, color) go through `PATCH /api/v2/highlights/<id>/`. The Readwise id comes from `GET /api/v2/highlights/?book_id=` (match `url` to our `highlight_url`) and is kept in the local-only `readwise_highlight` table (`highlight_id` PK, `readwise_highlight_id`, `updated_at`; migration `v7_readwise`).
  - Rate limit is 240/min (list endpoints 20/min); a 429 includes `Retry-After`.
  - Tags go in the note on create as a first line of `.tag` tokens, then the note ([blog](https://blog.readwise.io/tag-your-highlights-while-you-read/)). One word per tag. Later tag changes aren't pushed.
- **Quote as image:** render a SwiftUI card with `ImageRenderer` (iOS 16+) **(unverified tonight)**, then share it through `ShareLink`.

## 11. Sources

- **Readium**
  - [Repo](https://github.com/readium/swift-toolkit)
  - [CHANGELOG main](https://raw.githubusercontent.com/readium/swift-toolkit/main/CHANGELOG.md)
  - [CHANGELOG develop](https://raw.githubusercontent.com/readium/swift-toolkit/develop/CHANGELOG.md)
  - [README](https://raw.githubusercontent.com/readium/swift-toolkit/main/README.md)
  - [LICENSE](https://raw.githubusercontent.com/readium/swift-toolkit/main/LICENSE)
  - [Package.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/Package.swift)
  - Guides:
    - [SwiftUI](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/SwiftUI.md)
    - [Decorations](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Decorations.md)
    - [Highlights](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Highlights.md)
    - [Preferences](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Preferences.md)
    - [EPUB Fonts](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/EPUB%20Fonts.md)
    - [Navigator](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Navigator/Navigator.md)
    - [Search](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Search.md)
    - [TTS](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/TTS.md)
    - [Content](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Guides/Content.md)
    - [Timeline (4.0)](https://raw.githubusercontent.com/readium/swift-toolkit/develop/docs/Guides/Timeline.md)
    - [Migration Guide](https://raw.githubusercontent.com/readium/swift-toolkit/main/docs/Migration%20Guide.md)
  - Source files:
    - [Locator.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/Sources/Shared/Publication/Locator.swift)
    - [EPUBPositionsService.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/Sources/Streamer/Parser/EPUB/Services/EPUBPositionsService.swift)
    - [utils.js](https://raw.githubusercontent.com/readium/swift-toolkit/main/Sources/Navigator/EPUB/Scripts/src/utils.js)
  - TestApp:
    - [README](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/README.md)
    - [project.yml](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/Integrations/SPM/project.yml)
    - [Database.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/Sources/Data/Database.swift)
    - [Highlight.swift](https://raw.githubusercontent.com/readium/swift-toolkit/main/TestApp/Sources/Data/Highlight.swift)
  - Locator spec:
    - [Locator model](https://readium.org/architecture/models/locators/)
    - [HTML extension](https://readium.org/architecture/models/locators/extensions/html.html)
  - Release notes:
    - [3.11.0](https://blog.readium.org/release-note-swift-toolkit-version-3-11-0/)
    - [4.0.0-alpha.1](https://blog.readium.org/release-note-swift-toolkit-version-4-0-0-alpha-1/)
- **Alternatives**
  - foliate-js:
    - [README](https://raw.githubusercontent.com/johnfactotum/foliate-js/main/README.md)
    - [LICENSE](https://raw.githubusercontent.com/johnfactotum/foliate-js/main/LICENSE)
  - [epub.js on npm](https://registry.npmjs.org/epubjs)
  - Readest:
    - [README](https://raw.githubusercontent.com/readest/readest/main/README.md)
    - [LICENSE](https://raw.githubusercontent.com/readest/readest/main/LICENSE)
  - [Thorium iOS](https://apps.apple.com/app/id6745025189)
  - [VReader](https://github.com/lllyys/vreader)
  - [EPUBReaderSwiftUI](https://github.com/jtcodes/epubreaderswiftui)
  - [FolioReaderKit](https://awesome.ecosyste.ms/projects/github.com%2FFolioReader%2FFolioReaderKit)
  - [EPUBKit](https://swiftpackageindex.com/witekbobrowski/EPUBKit)
- **Storage and sync**
  - SwiftData:
    - [updates](https://developer.apple.com/documentation/updates/swiftdata.md)
    - [CloudKit sync](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices.md)
    - [CloudKitDatabase](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct.md)
    - [aggregation thread](https://developer.apple.com/forums/thread/832186)
    - [unique thread](https://developer.apple.com/forums/thread/756669)
    - [iOS 26 sync bug](https://developer.apple.com/forums/thread/811675)
  - GRDB:
    - [CHANGELOG](https://raw.githubusercontent.com/groue/GRDB.swift/master/CHANGELOG.md)
    - [README](https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md)
    - [GRDBQuery](https://github.com/groue/GRDBQuery)
  - SQLiteData:
    - [README](https://raw.githubusercontent.com/pointfreeco/sqlite-data/main/README.md)
    - [SPI](https://swiftpackageindex.com/pointfreeco/sqlite-data)
    - [1.0 post](https://forums.swift.org/t/sqlitedata-1-0-an-alternative-to-swiftdata-with-cloudkit-sync-and-sharing/82211)
  - CKSyncEngine:
    - [doc](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5.md)
    - [sample](https://github.com/apple/sample-cloudkit-sync-engine)
    - [mjtsai](https://mjtsai.com/blog/2026/04/01/cksyncengine/)
  - SQLite:
    - [window functions](https://www.sqlite.org/windowfunctions.html)
    - [iOS versions](https://theapplewiki.com/wiki/Databases)
- **Anchoring**
  - [W3C annotation model](https://www.w3.org/TR/annotation-model/)
  - [EPUB CFI](https://w3c.github.io/epub-specs/epub33/epubcfi/)
  - [Hypothesis blog](https://web.hypothes.is/blog/fuzzy-anchoring/)
  - [match-quote.ts](https://raw.githubusercontent.com/hypothesis/client/main/src/annotator/anchoring/match-quote.ts)
- **Apple platform**
  - Accounts:
    - [Compare memberships](https://developer.apple.com/support/compare-memberships/)
    - [Supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)
    - [Program](https://developer.apple.com/programs/)
  - TestFlight:
    - [overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
    - [product page](https://developer.apple.com/testflight/)
  - [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device.md)
  - [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups.md)
  - Files and import:
    - [UTType.epub](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/epub.md)
    - [CFBundleDocumentTypes](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes.md)
    - [LSSupportsOpeningDocumentsInPlace](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace.md)
    - [fileImporter](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:).md)
    - [security scope](https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource().md)
    - [onOpenURL](https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:).md)
    - [copy-then-display thread](https://developer.apple.com/forums/thread/756307)
    - [Inbox thread](https://developer.apple.com/forums/thread/801090)
    - [QA1893](https://developer.apple.com/library/archive/qa/qa1893/_index.html)
    - [ubiquity thread](https://developer.apple.com/forums/thread/774121)
  - WidgetKit:
    - [updates](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date.md)
    - [interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities.md)
  - [WebKit process termination](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:).md)
- **EPUB spec**
  - [EPUB 3.3](https://www.w3.org/TR/epub-33/)
  - [core source](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/core/index.html)
  - [RS source](https://raw.githubusercontent.com/w3c/epub-specs/main/epub33/rs/index.html)
  - [EPUB A11y 1.1](https://www.w3.org/standards/history/epub-a11y-11/)
- **Export**
  - Readwise:
    - [api_deets](https://readwise.io/api_deets)
    - [Markdown export](https://docs.readwise.io/readwise/docs/exporting-highlights/markdown-csv)
    - [importing](https://docs.readwise.io/readwise/docs/importing-highlights)
  - Obsidian:
    - [properties](https://obsidian.md/help/properties)
    - [callouts](https://obsidian.md/help/callouts)
