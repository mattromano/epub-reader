# Stats tab — design (project 2 of 2)

Date: 2026-11-23. Approved by Matt in conversation; he chose layout C and the screen list below. This branch is stacked on `reader-stats`.

## Intent

Reading stats are the heart of Margins. The Stats tab becomes a dashboard you can take in at a glance, with a drill-down screen for each area.

## Layout (C: overview plus drill-down cards)

**Overview (top to bottom)**
1. **Today card.** The goal ring plus the current streak, and pace "262 wpm" with "↑4% vs 90-day". The pace comparison is 14 days against 90 days.
2. **Lifetime strip.** Hours read, words read, "≈ N novels" (90k words each), and books finished.
3. **Minutes per day.** A compact chart for the last 30 days.
4. **Five navigation cards**, each with a headline number:
   - **Speed:** 14-day pace and delta.
   - **Sessions:** count this week and median minutes.
   - **Personal bests:** the longest session.
   - **Year in reading:** hours this year.
   - **Books:** the number in progress.

**Detail screens**
- **Speed**
  - A 30 d / 90 d / 1 y picker.
  - WPM trend: the existing chart, with its rolling median.
  - Pages/min trend.
  - WPM by book, by time band (Morning 05–11, Afternoon 12–16, Evening 17–21, Night 22–04), and by font size.
  - A group needs at least 10 pace-eligible minutes to be shown.
- **Sessions**
  - A session-length histogram, with buckets at 0, 5, 10, 20, 30, 45 and 60+ minutes.
  - A log grouped by reading day: book, start time, length, WPM and pages. It shows the 200 most recent sessions.
- **Personal bests**, each with its date and book where it applies:
  - longest session;
  - fastest session, counting only pace-eligible sessions of 10 minutes or more;
  - most minutes in a day;
  - most words in a day;
  - most pages in a session;
  - longest streak.
- **Year in reading**
  - A year picker.
  - A GitHub-style calendar.
  - Hours per month.
  - Books finished per month and the time-of-day heatmap (both moved here from the overview).
- **Books**
  - Books with at least one session, most recently read first, each with time, WPM and %.
  - Tapping one opens **Book stats**:
    - totals from `agg_book_stats`;
    - a projected finish date (words left ÷ words per day on this book over the last 14 days);
    - minutes and WPM per chapter, from counted location events with each gap capped at 180 s;
    - highlights per 10k words;
    - that book's sessions.
  - The Library book detail sheet links to the same Book stats page.

## Approaches considered

There is one sensible approach, and it follows the existing pattern:
- all aggregation lives in Metrics SQL, with golden tests;
- views read through GRDBQuery requests;
- Swift Charts draws the charts.

A precomputed `agg_*` table for records and breakdowns was rejected. A personal library is small, so on-demand SQL is fast. New aggregate tables would also add rebuild paths for no gain.

## Constraints

- CLAUDE.md rules apply: SQL with CTEs and bind parameters, no Swift-loop aggregation, soft-delete filters, and BookKit with no UIKit.
- Charts: per CLAUDE.md, use `RectangleMark` if `BarMark` doesn't render on iOS 27.
- No schema changes.

## Calls made by Claude (flag if wrong)

- **Fastest-session threshold:** 10 minutes.
- **Novel size:** 90k words.
- **Projection window:** 14 days.
- **Chapter pace:** gaps capped at 180 s.
- **Session log:** limited to 200 sessions.
- **Time bands:** as listed above.
- **Week:** "this week" means the last 7 reading days.
