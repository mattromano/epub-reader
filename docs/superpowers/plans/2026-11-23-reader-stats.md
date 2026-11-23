# Reader Stats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bigger reader scrubber, a live stats panel on tap, an optional always-on stats line, and a Settings screen that picks the stats for each.

**Architecture:**
- **Live numbers.** They come from a pure read-only snapshot of the in-memory `SessionTracker`.
- **Baselines.** Usual pace, today's finished minutes, the goal and time left come from Metrics SQL.
- **Calculator.** A pure `ReaderStatsCalculator` in BookKit turns both into display strings, which keeps every rule unit-testable.
- **App wiring.** The app only wires the snapshot, baselines and settings into views.

**Tech Stack:** Swift 6.4, SwiftUI (iOS 27), GRDB 7 + GRDBQuery, Readium 3.11, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-23-reader-stats-design.md`. Read it fully, including the "Calls made after review" section.

**Contract (already committed, don't change signatures):**
- `Packages/BookKit/Sources/Tracking/LiveSessionStats.swift`
- `Packages/BookKit/Sources/Metrics/ReaderStat.swift`
- `Packages/BookKit/Sources/Metrics/ReaderStatsCalculator.swift`
- `Packages/BookKit/Sources/Metrics/ReaderStatsQueries.swift`
- `AppDatabase.settingJSON(_:key:)`

Stubs are marked `TODO(Task N)`. Metrics now depends on Tracking.

## Global Constraints

- BookKit never imports UIKit or Readium. Aggregation lives in Metrics SQL (CTE style, bind parameters, explicit columns). WPM uses word-index words only.
- Tests use Swift Testing `@Test`, red → green. Run `swift test --package-path Packages/BookKit` before calling a BookKit task done.
- **App changes**
  - Run `xcodegen generate` after adding files.
  - Build with `xcodebuild -project Margins.xcodeproj -scheme Margins -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath DerivedData build`, with 0 new warnings.
  - Then `git checkout Packages/BookKit/Package.resolved`.
- Never edit `.xcodeproj`. Never change the bundle ID or App Group.
- No SwiftUI gestures over the navigator: tap zones go through the navigator's tap observer.
- Commits are small and imperative, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A session that crosses the day-start hour** (live `localDate` ≠ baseline `today`): `today_vs_goal` adds no live time. Test in Task 2.
2. **Paused session:** the timer freezes, and `elapsedActiveSeconds` doesn't grow with `date`. Test in Task 1.
3. **A long stare before a page turn:** the running stretch is capped at `idleThreshold` (180 s), never wall-clock. Test in Task 1.
4. **Corrupt or old settings JSON:** garbage strings, unknown ids, duplicates, more than 3 line stats, an empty panel array. Unreadable input means defaults. Unknown ids are dropped. An empty array stays empty, because the user turned everything off. Test in Task 2.
5. **Nothing available** (fixed layout, unindexed, no session yet): `values` returns `[]`, and the app then hides the strip and the panel grid. Test in Task 2, with app behavior in Task 4.

---

### Task 1: Live session snapshot (Tracking) — parallel agent

**Files:**
- Modify: `Packages/BookKit/Sources/Tracking/LiveSessionStats.swift`, implementing `live(at:)`.
- Test: `Packages/BookKit/Tests/TrackingTests/LiveSessionStatsTests.swift` (new).

**Interfaces:**
- Produces: `SessionTracker.live(at: Date) -> LiveSessionStats?`.
- `SessionTracker.swift` holds the internal state (`phase`, `session.activeSeconds`, `lastActivityAt`, `wordsRead`, `pageTurns`, `pause`, `localDate`, `config.idleThreshold`). The extension is in the same module, so it can read them.

**Rules:**
- **Returns nil** when `session == nil` (idle or dormant).
- **`paceActiveSeconds`** = `session.activeSeconds`.
- **`elapsedActiveSeconds`**
  - Reading: `activeSeconds + min(max(0, date − lastActivityAt), idleThreshold)`.
  - Paused: `activeSeconds`, frozen.
- **`isPaused`** = `phase == .paused`.
- **`localDate`, `wordsRead`, `pageTurns`** come straight from the session.

- [ ] **Step 1: Write failing tests.** Drive a tracker with `handle(_:at:)`, building events the way `TrackingTests.swift` does. Tests:
  - `noSessionBeforeOpenIsNil`: a fresh tracker → `live(at:) == nil`.
  - `runningStretchCountsTowardTimerNotPace`: open at t0, pageTurn at t0+60 (words counted) → `live(at: t0+90)` has `paceActiveSeconds == 60`, `elapsedActiveSeconds == 90`, `pageTurns == 1`, `wordsRead > 0`.
  - `runningStretchIsCappedAtIdleThreshold`: open at t0, page turn at t0+10 → `live(at: t0+10+1000).elapsedActiveSeconds == 10 + 180`.
  - `pausedTimerIsFrozen`: open, page turn, `.background` at tB → `live(at: tB+500)` gives `isPaused == true`, and `elapsedActiveSeconds == live(at: tB+5).elapsedActiveSeconds`.
  - `endedSessionIsNil`: a pause longer than `sessionGap` followed by a `.tick` that ends the session → nil.
  - `liveDoesNotMutate`: `handle` outputs are unchanged whether or not `live` was called in between (compare the outputs of two identical trackers).
- [ ] **Step 2:** Run `swift test --package-path Packages/BookKit --filter LiveSessionStatsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `live(at:)`.
- [ ] **Step 4:** Run the full `swift test --package-path Packages/BookKit`. Expected: all pass. `FuzzyQuoteMatcherTests.longChapterStaysFast` is a known flaky timing test; re-run it alone if it fails.
- [ ] **Step 5:** Commit: `Add live session snapshot to SessionTracker`.

### Task 2: Settings codec and stats calculator (Metrics) — parallel agent

**Files:**
- Modify: `Packages/BookKit/Sources/Metrics/ReaderStat.swift`, implementing `decode`, `encodedPanelJSON` and `encodedLineJSON`.
- Modify: `Packages/BookKit/Sources/Metrics/ReaderStatsCalculator.swift`, implementing `text(for:input:style:)`.
- Test: `Packages/BookKit/Tests/MetricsTests/ReaderStatsSettingsTests.swift` and `ReaderStatsCalculatorTests.swift` (new).

**Interfaces:**
- Consumes: `LiveSessionStats` (Tracking), `TimeLeft` (Metrics), and the contract types.
- Produces: the implemented contract functions.

**Codec rules:**
- The panel JSON is an array of raw ids. The line JSON is `{"enabled":Bool,"stats":[ids]}`.
- A nil or unparsable value means that part's default.
- Unknown ids are dropped.
- Duplicates keep the first occurrence.
- The line is cut to 3.
- An empty array is kept.
- Encoding uses `JSONEncoder` with `.sortedKeys`.
- Round trip: `decode(encoded…) == self`.

**Calculator rules.** Exact copy for `.full` style, then the `.compact` variant. A nil result means "leave the stat out".

| stat | full | compact | nil when |
|---|---|---|---|
| chapterTimeLeft | "12 min left in chapter" | "12 min left" | `timeLeft?.chapterMinutes == nil` |
| bookTimeLeft | "4 h 10 m left in book" | "4 h 10 m in book" | `timeLeft?.bookMinutes == nil` |
| bookPercent | "41%" | "41%" | `bookProgression == nil` |
| sessionTime | "23:41"; "1:02:41" at ≥ 1 h (`elapsedActiveSeconds`, floored) | same | `live == nil` |
| sessionWPM | "260 wpm" (`wordsRead / (paceActiveSeconds/60)`, rounded to nearest 5); "— wpm" while gated | same | `live == nil` |
| wpmVsUsual | "+8% vs usual" / "−3% vs usual" (U+2212) / "same as usual" when \|Δ\| < 0.5% | "+8%" / "−3%" / "±0%" | `live == nil`, `usualWPM == nil`, or gated |
| sessionWords | "6,020 words" / "1 word" | same | `live == nil` |
| sessionPages | "31 pages" / "1 page" | same | `live == nil` or `isScrollMode` |
| pagesPerMinute | "1.3 pages/min" (1 decimal); "— pages/min" while gated | same | `live == nil` or `isScrollMode` |
| todayVsGoal | "18 / 30 min today"; "18 min today" with no goal | "18/30 min"; "18 min" | `baseline == nil` |

- **Minute formatting** (time left): "45 min", "1 h 5 m", "1 h", and "<1 min" when > 0 but it rounds to 0. Port `ReadingTimeFormat.minutes`.
- **Gating:** gated means `paceActiveSeconds < minPaceSeconds || wordsRead < minPaceWords`.
- **Speed vs usual:** Δ = (sessionWPM_unrounded / usualWPM − 1) × 100, rounded to an integer.
- **Today's minutes:**
  - `floor((todayFinishedSeconds + liveExtra) / 60)`.
  - `liveExtra` is `live.elapsedActiveSeconds` only when `live.localDate == baseline.today`, otherwise 0.
  - The goal is shown as `Int(goalMinutes.rounded())`.
- **Number grouping** uses `Locale(identifier: "en_US")`, so tests are deterministic.

- [ ] **Step 1: Write failing tests**
  - **Settings tests**
    - `missingRowsGiveDefaults`
    - `roundTrip`
    - `unknownIdsAreDropped` (`["chapter_time_left","bogus"]` → `[.chapterTimeLeft]`)
    - `duplicatesKeepFirst`
    - `lineIsCappedAtThree`
    - `garbageJSONGivesThatPartsDefault`
    - `emptyPanelStaysEmpty`
    - `lineDisabledRoundTrips`
  - **Calculator tests:** one `@Test(arguments:)` table with every row above (full and compact). Plus:
    - `gatedSpeedShowsDash` (119 s or 149 words → "— wpm", and `wpmVsUsual` nil)
    - `wpmRoundsToNearestFive` (262 → "260", 263 → "265")
    - `todayExcludesLiveSessionFromAnotherDay` (Review Focus 1)
    - `todayWithoutGoal`
    - `scrollModeHidesPages`
    - `nothingAvailableGivesEmptyValues` (live nil, baseline nil, timeLeft nil, progression nil → `values(ReaderStat.allCases…) == []`; Review Focus 5)
    - `valuesKeepOrder`
- [ ] **Step 2:** Run `swift test --package-path Packages/BookKit --filter "ReaderStats"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the full `swift test --package-path Packages/BookKit`. Expected: all pass.
- [ ] **Step 5:** Commit: `Implement reader stats settings codec and calculator`.

### Task 3: Baseline and settings queries (Metrics) — parallel agent

**Files:**
- Modify: `Packages/BookKit/Sources/Metrics/ReaderStatsQueries.swift`.
- Test: `Packages/BookKit/Tests/MetricsTests/ReaderStatsQueriesTests.swift` (new).

**Interfaces:**
- Consumes:
  - `MetricsQueries.today(_:now:timeZone:)`
  - `MetricsQueries.bookPace(_:bookID:today:)` (already falls back to rolling pace)
  - `GoalRequests.current(.dailyMinutes)`
  - `AppDatabase.settingJSON(_:key:)`
  - `ReaderStatsSettings.decode`
- Produces: the three implemented functions.

**Rules:**
- **`todayFinishedActiveSeconds`:**
  - SQL in a static string with a doc comment naming the reader-stats design.
  - `SUM(active_seconds)` from `fact_reading_session` where `deleted_at IS NULL AND local_date = :today`.
  - Returns 0 when there are none.
  - Counts all books and all sessions, pace-eligible or not.
- **`readerStatsBaseline`:**
  - `today` comes from `MetricsQueries.today(db, now:, timeZone:)`.
  - `usualWPM` comes from `bookPace`.
  - `goalMinutes` is `GoalRequests.current(.dailyMinutes).fetchOne(db)?.target`.
- **`readerStatsSettings`:** `ReaderStatsSettings.decode(panelJSON: settingJSON(db, panelKey), lineJSON: settingJSON(db, lineKey))`.

- [ ] **Step 1: Write failing tests.** Seed with the same `AppDatabase.inMemory()` and the same session-insert helpers that `MetricsTests.swift` uses. Tests:
  - `todaySumsFinishedSessionsOnlyForThatDay`: 2 sessions today (600 s + 300 s), 1 yesterday, 1 soft-deleted today → 900.
  - `todayIsZeroWithNoSessions`.
  - `baselineCarriesGoalAndPace`: set a goal of 30 via `setGoal`, then seed ≥ 15 eligible minutes on the book → `goalMinutes == 30` and `usualWPM` equals `bookPace`.
  - `baselineWithoutGoalOrPace`: nil, nil.
  - `settingsDefaultWhenUnset`.
  - `settingsReadBackAfterWrite`: `setSettingJSON(custom.encodedPanelJSON(), forKey: panelKey)` and the same for line, then read → `== custom`. This depends on Task 2's codec. If Task 2 hasn't merged, hand-write the JSON strings from the codec rules, and the test passes after the merge.
- [ ] **Step 2:** Run `swift test --package-path Packages/BookKit --filter ReaderStatsQueriesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the full suite. Expected: all pass, except `settingsReadBackAfterWrite` before Task 2 merges; note it if so.
- [ ] **Step 5:** Commit: `Add reader stats baseline and settings queries`.

### Task 4: Reader UI — scrubber, panel, strip (app) — main session

**Files:**
- Create: `Margins/Features/Reader/ReaderStatsPanel.swift` (scrubber + stats grid view).
- Create: `Margins/Features/Reader/ReaderStatsLine.swift` (the strip).
- Modify:
  - `Margins/Features/Reader/ReaderView.swift` (replace the `scrubber` toolbar item, add the strip overlay)
  - `ReaderViewModel.swift` (baseline, settings observation, live refresh)
  - `TrackerDriver.swift` (expose `live(at:)`, and report when a session row lands)
  - `ReaderHostViewController.swift` (bottom content inset when the strip is enabled)

**Interfaces:**
- Consumes: everything in the contract.
- Produces:
  - `TrackerDriver.liveStats() -> LiveSessionStats?`, which is `tracker.live(at: clock.now)`.
  - `TrackerDriver.onSessionEnded: (() -> Void)?`, called after a `.sessionEnded` write lands.

**Decisions:**
- **`ReaderViewModel` state**
  - `statsSettings: ReaderStatsSettings`, observed through a `ValueObservation` of `MetricsQueries.readerStatsSettings`.
  - `baseline: ReaderStatsBaseline?`, reloaded on open, on `onSessionEnded`, and on chapter change (where time left already refreshes).
  - `panelValues: [ReaderStatValue]` and `lineValues: [ReaderStatValue]`, recomputed by `refreshStats()` on every location change.
  - A timer runs while the chrome is visible (1 s) or the strip is showing (15 s). It's cancelled when neither is on screen.
- **Scrubber**
  - `Slider` replaced by a custom bar: an 8 pt track and a 28 pt thumb, with a 44 pt-tall hit area across the full width.
  - Dragging sets `scrubValue`; release seeks (existing `seek(to:)`). A tap on the track seeks.
  - The label above the bar is `.subheadline`: chapter · %. While dragging it shows only "%".
  - Keep the accessibility label and value.
- **Panel**
  - The bottom chrome becomes a multi-row view: scrubber, then a 2-column grid of `panelValues` (`.subheadline`, monospaced digits, SF Symbol per stat optional).
  - If the system `.bottomBar` can't host multiple rows cleanly on iOS 27, use `.safeAreaInset(edge: .bottom)` with `.glassEffect()` (or the iOS 27 equivalent), shown and hidden with the existing chrome state.
- **Strip**
  - `.caption`, `.secondary`, centered, `lineValues` (compact style) joined with " · ".
  - Shown when the chrome is hidden, `statsSettings.lineEnabled`, `lineValues` isn't empty, and the book isn't fixed layout.
  - Overlaid at the bottom inside the reserved inset.
- **Inset**
  - When the strip is enabled at open, set `contentInset` on `EPUBNavigatorViewController.Configuration` for the `.compact` and `.regular` size classes, with bottom = existing default + 24 pt.
  - It isn't toggled live (spec call 8).

- [ ] **Step 1:** Add `liveStats()` and `onSessionEnded` to `TrackerDriver`.
- [ ] **Step 2:** Add the stats state, settings observation, baseline loading, `refreshStats()` and the timer to `ReaderViewModel`.
- [ ] **Step 3:** Build `ReaderStatsPanel` (scrubber + grid) and `ReaderStatsLine`, then wire them into `ReaderView`.
- [ ] **Step 4:** Add the navigator content inset.
- [ ] **Step 5:** Run `xcodegen generate` and the app build. Expected: BUILD SUCCEEDED, 0 new warnings.
- [ ] **Step 6:** Commit: `Show live reading stats in the reader`.

### Task 5: Reader Stats settings screen (app) — parallel agent

**Files:**
- Create: `Margins/Features/Settings/ReaderStatsSettingsView.swift`.
- Modify: `Margins/Features/Settings/SettingsView.swift`, adding a `NavigationLink("Reader Stats")` section before `ReadwiseSettingsSection()`.

**Interfaces:**
- Consumes:
  - `ReaderStatsSettings`
  - `ReaderStat.title`
  - `MetricsQueries.readerStatsSettings`
  - `AppDatabase.setSettingJSON(_:forKey:)`
- Reading is a GRDBQuery `@Query` of a `ValueObservationQueryable` request wrapping `readerStatsSettings`, in the same pattern as `CurrentGoalRequest` in `SettingsView.swift`.

**Decisions:**
- **Section "Always-on line"**
  - A toggle (`lineEnabled`).
  - The chosen stats as a reorderable list (`.onMove`).
  - Below them, the unchosen stats as buttons that add them. They're disabled once 3 are chosen, and the footer says "Up to 3.".
  - Swipe removes a stat.
  - Footer: "Shows under the page while you read. Turning it on or off applies the next time you open a book."
- **Section "Tap panel"**
  - All stats. Each row has a checkmark or toggle for inclusion.
  - Included stats come first in panel order and are reorderable. The rest follow.
- **"Reset to Defaults" button:** writes `ReaderStatsSettings.default`.
- **Saving:** every change writes both keys at once through `setSettingJSON` in a `Task`.
- The list is always in edit mode for reordering (`.environment(\.editMode, .constant(.active))`), or uses an Edit button. Builder's call.

- [ ] **Step 1:** Build the view and the link.
- [ ] **Step 2:** Run `xcodegen generate` and the app build. Expected: BUILD SUCCEEDED, 0 new warnings.
- [ ] **Step 3:** Commit: `Add Reader Stats settings screen`.

### Task 6: Integrate and verify — main session

- [ ] **Step 1:** Merge the agent branches into `reader-stats`.
- [ ] **Step 2:** Run the full `swift test --package-path Packages/BookKit`. Expected: all pass, including `settingsReadBackAfterWrite`.
- [ ] **Step 3:** Run the app build. Expected: 0 warnings.
- [ ] **Step 4:** Check in the simulator (iPhone 18 Pro, iOS 27.2). Import a test book (`python3 scripts/make_test_epubs.py TestBooks`), open it, turn pages, and take screenshots of:
  - the panel showing on tap;
  - the strip with the chrome hidden, not overlapping text;
  - the larger scrubber;
  - a Settings change, after which the panel updates.
- [ ] **Step 5:** Run a whole-branch review (`superpowers:requesting-code-review`), then fix what it finds.
- [ ] **Step 6:** Push the branch and open a PR.
