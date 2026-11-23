# Open questions and decisions for Matt

All ten questions were decided on Nov 22. Items that can only be settled by building are listed at the bottom with the milestone where they get checked.

1. **When to pay the $99 Apple Developer Program** (decided Nov 22)
   - Free tier gives 7-day installs, 3 devices, 3 apps per device, and 10 App IDs per 7 days, with no iCloud or CloudKit ([Apple](https://developer.apple.com/support/compare-memberships/), [capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)).
   - **Decision:** stay free through M7. Pay before M8 (iCloud sync).
   - **Accepted risk:** moving from the free Personal Team to a paid team may change the signing team, and the app's data could be lost to a delete-and-reinstall. Apple's docs didn't confirm this either way. Forum reports say a bundle ID stays reserved to the Personal Team **(unverified)**. If that happens, on-device reading history from before M8 could be lost. No backup step is planned; recheck this before enrolling.
2. **Minimum iOS version** (decided Nov 22)
   - Your iPhone is on iOS 27, so the app targets **iOS 27.0**, built with Xcode 27.1.
   - If TestFlight friends are on older iOS later, Readium (iOS 15+) and GRDB allow lowering it; only iOS 27-only APIs would need `if #available`.
3. **Storage starting point** (decided Nov 22)
   - **Decision:** plain GRDB now, with a sync-ready schema. Add SQLiteData's SyncEngine at M8.
4. **Reading-day boundary** (decided Nov 22)
   - **Decision:** the day starts at **04:00** local, so reading after midnight counts toward the previous day for streaks.
   - If you change the hour later, it applies only to new sessions. Past sessions keep their reading-day, because facts are append-only (SPEC §5).
5. **Streak rule** (decided Nov 22)
   - **Decision:** a day counts toward the streak with at least **5 active minutes**. The daily goal is separate and defaults to **30 minutes**.
6. **Idle and session thresholds** (decided Nov 22)
   - **Decision:** **180 s** with no page turn counts as idle. A gap of **300 s** or more starts a new session.
   - Both can be changed in Settings. Tune them after a week of real data (M2).
7. **Fixed-layout books (comics, picture books)** (decided Nov 22)
   - **Decision:** they open read-only, with no Aa sheet. Time is tracked, but words and WPM aren't.
8. **Primary export target** (decided Nov 22)
   - **Decision:** Markdown for Obsidian, plus CSV, in the MVP (M4). Readwise API push comes after the MVP (M7).
9. **Book file sync** (decided Nov 22)
   - **Decision:** books stay on the device until M8, then move to an iCloud Drive "Margins/Books" folder. Only metadata syncs through CloudKit.
10. **App name / bundle ID** (decided Nov 22)
    - Display name: **Margins**. This can change at any time.
    - Bundle ID: **`com.mattromano.margins`**.
    - App Group: **`group.com.mattromano.margins`**.
    - The bundle ID and App Group ID are permanent. Changing either one later orphans the app's data on your phone.

## Deferred to a milestone (check while building; not open decisions)

- **M0**
  - Readium 3.11 and GRDB 7 build with Xcode 27.1.
  - The SQLite version on iOS 27 is ≥ 3.25. Add a startup assertion on `sqlite_version()`.
- **M1**
  - Check whether Readium de-obfuscates IDPF fonts. Test with a sample file.
  - Check VoiceOver inside the reader web view.
- **M2**
  - Check `NLTokenizer(.word)` counts against fixture text.
  - Tune the idle and session-gap thresholds.
- **M4**
  - ✓ FTS5 sync: plain SQL triggers on `fact_highlight` and `dim_book` (title/authors) keep a standalone `fts_highlight` in sync (`v5_highlight_search`); GRDB's FTS5 Swift API isn't needed. Search is prefix-per-word, all words required.
  - ✓ `ImageRenderer` works for quote images (360 pt card at 3x, shared as a PNG through `ShareLink`). Sharing to Messages is device-only: the simulator has no Messages share target.
  - ✓ Exports are lazy `Transferable` files (`FileRepresentation`), written to `tmp/Exports/<uuid>/` only when the share sheet asks.
  - Re-anchor on open compares `chapter_text_hash` with `dim_chapter.text_hash`. A match rewrites `char_start/char_end`; the stored locator JSON is left as is (Readium re-anchors by quote). The fuzzy re-anchor is split out as **M4.5**.
  - `total_progression` on a highlight is the page's, not the selection's (Readium's selection locator), so highlights on the same page tie; the Quotes "By Book" order breaks ties by `created_at`.
- **M4.5**
  - ✓ Fuzzy re-anchor ports Hypothesis's scoring (quote 50 / prefix 20 / suffix 20 / position 2, `maxErrors = min(256, len/2)`) over the whitespace-free projection, using Sellers' semi-global edit distance with Ukkonen's cutoff: about 37 ms (release) on a 230k-character chapter. Missing prefix, suffix or hint score 1, as in Hypothesis.
  - Accepted at ≥ 0.75; below that the highlight is `orphaned`. A fuzzy hit stores `anchor_score`, `char_start/char_end`, `progression` (character-based) and rewrites the locator's `text` and `locations.progression`. `quote_exact` stays as captured, so exports keep what you highlighted.
  - Not checked in the simulator: it needs a replaced book file with the same book row, which only a re-import-in-place (later) produces. Covered by unit tests.
- **M5**
  - ✓ Aggregates refresh in the same transaction as every session and highlight write. The refresh SQL lives in Persistence, not Metrics, because Metrics depends on Persistence and the write paths need it. Metrics holds the read-side queries.
  - `agg_daily_reading` is sparse (only days with reading or highlights); charts don't fill the gaps. Highlights are bucketed into reading days from their UTC `created_at` with the current day-start hour, so a rebuild after changing the hour re-buckets highlights but not sessions.
  - The weekday heatmap uses the weekday of the reading day: a 2 am session counts at hour 2 of the previous day's weekday.
  - `pct_complete` is the furthest `end_word_idx` ÷ book words, falling back to `last_total_progression`.
  - The deleted-book question is open: a soft-deleted book's sessions still count in daily totals and streaks. SPEC doesn't say either way.
  - ✓ The dashboard fetch takes 11 ms (30 days) and 27 ms (1 year) in a debug build with 1,368 synthetic sessions over 2 years.
  - The idle and session-gap thresholds (#6) still use the tracker defaults; Settings has goal, day start and streak minimum only.
- **M6**
  - ✓ The app writes `widget_snapshot.json` (BookKit `WidgetData`, built by `MetricsQueries.widgetSnapshot`) on launch, on reader close and when the scene goes to the background, then reloads all timelines. The widget never opens the DB.
  - ✓ The timeline has two entries: now, and the next reading-day start (local midnight + day-start hour), where today's minutes reset and the streak shows "at risk" or breaks. Policy `.atEnd`, so WidgetKit asks again after the rollover.
  - ✓ In the simulator: small and medium render the real snapshot (cover included), the medium widget went from 6% / 57 min left / 10 min today to 11% / 54 min / 11 min within seconds of closing the reader, and tapping it opened the reader at the last position.
  - The Lock Screen (accessoryRectangular) family wasn't checked in the simulator; check it on the phone.
  - "Continue reading" is the most recently opened or read book that isn't finished or abandoned. With no such book the medium widget falls back to the small layout.
  - A widget tap while a different book is open closes it first (its session is saved), then opens the widget's book. Same book: nothing happens. Known gap: this only covers a reader opened from the Library tab. With a reader opened from Quotes (jump to a highlight), the tap switches to Library underneath and the new reader can't present until that one closes.
  - Settings changes (goal, streak minimum, day start) reach the widget at the next background or reader close, not instantly.
- **M7**
  - ✓ Inline tags: a first line of `.tag` tokens, then the note ([blog](https://blog.readwise.io/tag-your-highlights-while-you-read/)). A tag is one word; spaces become `-`. Not checked against the live API yet.
  - ✓ A re-POST with the same `highlight_url` updates the text only ("Pass the same url with a new text"); Readwise dedupes on title/author/text/source_url, so a note-only change would be ignored. Edits therefore go through `PATCH /highlights/<id>/` (text, note, color). Ids come from listing each touched Readwise book (`GET /highlights/?book_id=`) and matching `url` to `margins://highlight/<uuid>`; they live in the local-only `readwise_highlight` table (`v7_readwise`), not on the synced `fact_highlight`.
  - Assumes the list's `url` field echoes the `highlight_url` we sent (the docs imply it, the example shows null). If it doesn't, ids never resolve: new highlights still arrive, but note edits don't update. Check on the first real push (Settings shows nothing pending afterwards either way).
  - Tags are sent once, on create. Later tag changes don't propagate, and PATCH sends the note without the tag line. Color is sent only through PATCH, so a new highlight lands yellow until its first edit.
  - Soft-deleted highlights stay in Readwise (no DELETE); a highlight deleted in Readwise is re-created on its next edit (PATCH 404 → POST).
  - Pushes run from Settings and when the app goes to the background (inside a background task, waiting at most 5 s on a 429). One push at a time.
  - Re-anchoring (M4.5) bumps `updated_at`, so a re-anchored highlight is re-sent; harmless (idempotent).
- **M8**
  - SQLiteData `SyncEngine` vs a hand-rolled `CKSyncEngine`.
  - Confirm team-switch behavior before enrolling (see #1).
