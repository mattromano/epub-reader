# Reader stats — design (project 1 of 2)

Date: 2026-11-23. Status: draft for approval.

## Intent

Reading stats are meant to be a central part of Margins, not something buried in a tab. While reading, Matt wants to see at a glance:
- how long until the end of the chapter;
- how fast he is reading in this session, as live WPM.

The reader also has a progress scrubber at the bottom. On the phone it is far too small.

Project 2, a richer Stats tab, comes later and has its own design. It will cover:
- a session log;
- speed broken down by book, by time of day and by font size;
- personal bests;
- lifetime totals and a year heatmap;
- a per-book view.

## Goals

1. **A bigger scrubber.** The progress bar at the bottom of the reader becomes easy to grab, and its labels become readable.
2. **A stats panel on tap.** Tapping the center of the page shows the chrome, and the bottom of the chrome now holds a panel of live stats.
3. **An optional one-line strip.** While the chrome is hidden, one small line of up to 3 stats can stay at the bottom of the page.
4. **Configurable in Settings.** Settings chooses which stats appear in the panel and in what order. It also chooses the strip's stats and whether the strip shows at all.
5. **Live numbers.** Session stats update on every page turn, and the session timer keeps counting while the panel is open.

## Non-goals

- Stats tab changes. Those are project 2.
- New tracking. Everything needed is already in the tracker and DB.
- Sync. The settings rows are already sync-shaped (`app_setting`), and that's enough.
- Widgets.

## Anti-goals (failure even if it "works")

- The strip covers or crowds the text.
- Numbers jump around or lag noticeably behind page turns.
- A live WPM that is obviously garbage in the first seconds of a session, like "1,400 wpm" after one page.
- Stats math in the app layer that disagrees with what the Stats tab later reports for the same session.

## Approaches considered

- **A. Live numbers from the in-memory tracker (chosen).**
  - `SessionTracker` already holds the running `activeSeconds`, `wordsRead` and `pageTurns` of the session in progress.
  - We expose a read-only snapshot and render it on every location change and on a timer.
  - Baselines (usual pace, today's minutes so far, time left) come from the DB through existing `MetricsQueries`.
  - Instant, no extra writes, and it reuses the tested tracker math.
- **B. Watch the 30 s `session_draft` checkpoint in the DB (rejected).**
  - Single source of truth, but the numbers lag up to 30 s and jump.
  - Live WPM would feel broken.

Matt picked A.

## Decided with Matt

- **Inline stats.** Time left in chapter, and live session WPM.
- **Also included** (Matt: "those are all great stats"):
  - session timer;
  - WPM compared with usual pace;
  - today's minutes against the daily goal;
  - pages this session;
  - pages per minute.
- **Where stats show.** The full panel only shows when you tap. The simple one-line strip is optional.
- **Both are configurable in Settings.**

## Design

### Stat catalog

A `ReaderStat` enum lives in BookKit (`Metrics`). It is pure, has stable string raw values, and is `Codable`.

| id | label example | source |
|---|---|---|
| `chapter_time_left` | "12 min left in chapter" | `MetricsQueries.timeLeft` (existing) |
| `book_time_left` | "4 h 10 m left in book" | same |
| `book_percent` | "41%" | word-based % (SPEC §6.3), else Readium totalProgression |
| `session_time` | "23 min" | live tracker `activeSeconds` |
| `session_wpm` | "262 wpm" | live `wordsRead / activeMinutes` |
| `wpm_vs_usual` | "+8% vs usual" | live WPM against `bookPace` (falls back to rolling pace) |
| `session_words` | "6,020 words" | live `wordsRead` |
| `session_pages` | "31 pages" | live `pageTurns` |
| `pages_per_minute` | "1.3 pages/min" | live `pageTurns / activeMinutes` |
| `today_vs_goal` | "18 / 30 min today" | today's minutes from facts + live `activeSeconds`, against the goal valid today |

**Defaults.**
- Panel: `chapter_time_left`, `book_time_left`, `session_time`, `session_wpm`, `wpm_vs_usual`, `session_pages`, `pages_per_minute`, `today_vs_goal`.
- Strip: on, showing `chapter_time_left` and `session_wpm`.

### Live session snapshot (BookKit, Tracking)

- `SessionTracker.live(at: Date) -> LiveSessionStats?` returns `activeSeconds`, `wordsRead`, `pageTurns`, `scrollEvents` and `isPaused`.
- The function is pure and does not mutate the tracker. While reading, `activeSeconds` includes the running stretch up to `at`, capped by the same idle rule the tracker uses, so the timer never counts idle time. It returns nil when no session is in progress.
- Tests: a scenario table, like the existing tracker tests.

### Formatting and gating (BookKit, Metrics)

`ReaderStatsCalculator` is pure. It turns `LiveSessionStats`, the baselines and `TimeLeft` into a display value per `ReaderStat`: a string, or nil meaning "not available yet".

Gating rules (builder's call on exact numbers, but they must exist):
- **WPM, WPM vs usual and pages per minute** show "—" until the session has at least 2 active minutes and at least 150 words. This prevents "1,400 wpm" early in a session.
- **WPM vs usual** is hidden when there's no pace baseline.
- **Pages and pages per minute** are hidden in scroll mode, which has no pages.
- **Time left** is hidden until the book is indexed and a pace exists. This matches the current behavior.
- **WPM rounding.** WPM is rounded to the nearest 5, so it doesn't flicker between 261, 263 and 258.

Tests: golden tests for each stat and gate.

### Today's minutes baseline

- A metric query, `todayActiveSeconds(db, today:)`, sums `fact_reading_session.active_seconds` for `local_date = today`.
- The panel adds the live session on top. Sessions are written only when they end, so nothing is counted twice.
- The query re-runs when a session ends while the book is still open: the tracker emits a session row, and the app reloads the baseline.

### Settings storage

Two `app_setting` keys hold JSON values:
- `reader_stats_panel`: `["chapter_time_left", …]`. The order is the display order.
- `reader_stats_line`: `{"enabled": true, "stats": ["chapter_time_left","session_wpm"]}`. At most 3 stats.

Rules:
- Unknown ids are dropped when decoding, so older and newer app versions can share data.
- A missing key means the defaults.
- Encoding, decoding, the 3-stat cap and the defaults all live in BookKit and are tested.

### Settings UI

- Settings gets a **Reader Stats** row that opens a screen with two sections.
  - **Always-on line**
    - A toggle.
    - Pick up to 3 stats; once 3 are picked, the rest are disabled.
    - Reorderable.
  - **Tap panel**
    - Every stat, each with its own toggle.
    - Reorderable with drag handles.
- A "Reset to defaults" button.
- Changes apply live to an open reader. The reader observes the settings rows.

### Reader UI

```
┌──────────────────────────────────────┐   chrome visible (tap center)
│ Chapter 7 · The Long Night     41%   │
│ ━━━━━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━   │   taller track, big thumb, ≥ 44 pt hit area
│ 12 min left in chapter               │
│ ⏱ 23 min   262 wpm (+8%)   31 pages  │   stats grid, configured order
│ 1.3 pages/min   18 / 30 min today    │
└──────────────────────────────────────┘

        …page text…
      12 min left · 262 wpm              strip, chrome hidden, small caption, centered
```

**Scrubber.** Replaces the thin system slider squeezed into the bottom toolbar item.
- A thicker track.
- A large thumb.
- The chapter title and % at `.subheadline`, not `.caption`.
- Drag-to-seek behavior stays the same: the target % shows while dragging, and the jump happens on release.
- Tapping a spot on the track seeks there.

**Panel.** A grid of the configured stats under the scrubber, inside the bottom chrome.
- It refreshes on every location change and every second while visible, so the timer counts.
- It stops refreshing when hidden.
- How the bottom chrome is hosted (system bottom bar vs a custom glass panel) is the builder's call. Pick whatever fits a multi-row panel on iOS 27; CLAUDE.md prefers system chrome and Liquid Glass.

**Strip.** One line, `.caption`, secondary color, centered at the bottom of the page. Shown only when the chrome is hidden and the strip is enabled.
- **It must not cover text.** Reserve space with the navigator's content inset (Readium `EPUBNavigatorViewController.Configuration.contentInset`, or the equivalent) when the strip is enabled.
- It refreshes on location change and every 15 s.
- It is not shown for fixed-layout books.

### Where the code goes

- **BookKit**
  - `Tracking`: the `live(at:)` snapshot.
  - `Metrics`: `ReaderStat`, the calculator, the today baseline query, and the settings codec.
  - `Persistence`: typed getters and setters on top of `settingJSON`.
  - No UIKit or Readium, per the module rules.
- **App**
  - `TrackerDriver` exposes the live snapshot.
  - `ReaderViewModel` holds the baselines and the computed stat values.
  - The scrubber, panel and strip views in `Features/Reader/`.
  - The settings screen in `Features/Settings/ReaderStatsSettingsView.swift`.

### Calls made after review (Claude's calls, flagged for Matt)

1. **The time stat and the speed stats treat time differently.**
   - The `session_time` stat keeps ticking while you read, adding the time since your last page turn or scroll.
   - Once you've been inactive past the tracker's idle threshold, that extra time stops counting (the idle limit is `TrackerConfig.idleThreshold`).
   - WPM and pages/min only use active time up to the last location event, because words are counted only when a location event arrives. Between page turns the speed numbers hold steady, and they don't sag second by second.
   - Live numbers are display-only. The finished session row stays the source of truth; live values don't need to match it to the second.
2. **`today_vs_goal`.**
   - "Today" is the current reading day (`MetricsQueries.today`, which respects the day-start hour).
   - The live session is added only if its `localDate` is that day.
   - The goal is the `daily_minutes` goal row in effect today (SCD2). If no such row exists, the stat shows "18 min today" with no target. This needs a small new Metrics query, and it ignores the other goal kinds.
3. **Unavailable stats are left out, not shown as "—".** This covers fixed-layout books, unindexed books, scroll mode, and having no pace yet.
   - The panel and the strip show only the stats that have a value.
   - The one exception is the early-session gate: there, WPM shows "—" so you can see it's coming.
   - If nothing in the strip has a value, the strip is hidden.
4. **Paused or between sessions.**
   - While paused, the timer freezes. When a session has just ended and no new one has started, the session stats are left out of the panel.
   - Live numbers include short sessions that the tracker later discards (under 30 s). This is acceptable: it only affects the first seconds of reading.
5. **Baselines reload together.** `bookPace` (which falls back to rolling pace inside the existing query), time left, and today's minutes all reload:
   - when the book opens;
   - when a session row is written while the book is open;
   - when the chapter changes (time left, as today).

   Time left keeps using book pace, as SPEC §6.3 says, not the live session pace.
6. **`book_percent`** is the same % the scrubber shows (`ReaderViewModel.currentProgression`).
7. **Settings observation.** The reader watches the two `app_setting` rows with a new `ValueObservation` request. This is new code; nothing for it exists today.
8. **Strip inset.** Readium 3.11 has `EPUBNavigatorViewController.Configuration.contentInset` (`[UIUserInterfaceSizeClass: EPUBContentInsets]`). Set the bottom inset when the strip is enabled.
   - The configuration is fixed when the navigator is created. So switching the strip on or off takes effect the next time the book opens.
   - This is the one setting that doesn't apply live. The Settings footer says so.

## Constraints

- CLAUDE.md rules:
  - BookKit stays UIKit/Readium-free.
  - Aggregation lives in Metrics SQL.
  - WPM uses word-index words, never Readium positions.
  - No SwiftUI gestures over the navigator: tap zones use the navigator's tap observer.
- Main-thread work on page turns stays tiny. Baselines are loaded asynchronously; the live math is O(1).
- `app_setting` rows follow the synced-table rules: UUID primary key, soft delete, and the latest `updated_at` wins.

## Left to the builder

- Exact gate thresholds and rounding.
- The panel's grid layout.
- The chrome hosting approach.
- The strip's inset mechanism.
- SF Symbols.
- Copy wording.

## Verification

- `swift test --package-path Packages/BookKit` passes, with new suites for:
  - the live snapshot;
  - the calculator gates;
  - the settings codec;
  - the today baseline.
- The app builds with 0 warnings.
- In the iPhone 18 Pro simulator:
  - the scrubber is visibly larger;
  - the panel shows the configured stats;
  - the strip shows and hides with the chrome and doesn't overlap text;
  - Settings changes apply live.
- The final check happens on Matt's iPhone.
