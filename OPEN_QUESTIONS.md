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
- **M7**
  - Readwise inline tag syntax (check `api_deets`).
- **M8**
  - SQLiteData `SyncEngine` vs a hand-rolled `CKSyncEngine`.
  - Confirm team-switch behavior before enrolling (see #1).
