import Foundation
import Testing
@testable import Metrics

@Suite struct ReaderStatsSettingsTests {
    @Test func missingRowsGiveDefaults() {
        #expect(ReaderStatsSettings.decode(panelJSON: nil, lineJSON: nil) == .default)
    }

    @Test func roundTrip() {
        let s = ReaderStatsSettings(panel: [.bookPercent, .sessionWords, .todayVsGoal],
                                    lineEnabled: true, line: [.sessionTime, .bookTimeLeft])
        #expect(ReaderStatsSettings.decode(panelJSON: s.encodedPanelJSON(), lineJSON: s.encodedLineJSON()) == s)
        #expect(ReaderStatsSettings.default.encodedPanelJSON().hasPrefix("[\"chapter_time_left\""))
        #expect(ReaderStatsSettings.default.encodedLineJSON()
            == "{\"enabled\":true,\"stats\":[\"chapter_time_left\",\"session_wpm\"]}")
    }

    @Test func unknownIdsAreDropped() {
        let s = ReaderStatsSettings.decode(panelJSON: "[\"chapter_time_left\",\"bogus\"]",
                                           lineJSON: "{\"enabled\":true,\"stats\":[\"nope\",\"book_percent\"]}")
        #expect(s.panel == [.chapterTimeLeft])
        #expect(s.line == [.bookPercent])
    }

    @Test func duplicatesKeepFirst() {
        let s = ReaderStatsSettings.decode(
            panelJSON: "[\"session_wpm\",\"book_percent\",\"session_wpm\"]",
            lineJSON: "{\"enabled\":true,\"stats\":[\"book_percent\",\"session_wpm\",\"book_percent\"]}")
        #expect(s.panel == [.sessionWPM, .bookPercent])
        #expect(s.line == [.bookPercent, .sessionWPM])
    }

    @Test func lineIsCappedAtThree() {
        let s = ReaderStatsSettings.decode(
            panelJSON: nil,
            lineJSON: "{\"enabled\":true,\"stats\":[\"book_percent\",\"session_wpm\",\"session_time\",\"session_words\",\"session_pages\"]}")
        #expect(s.line == [.bookPercent, .sessionWPM, .sessionTime])
    }

    @Test func garbageJSONGivesThatPartsDefault() {
        #expect(ReaderStatsSettings.decode(panelJSON: "not json {", lineJSON: "[1,2") == .default)
        #expect(ReaderStatsSettings.decode(panelJSON: "{\"a\":1}", lineJSON: "[\"book_percent\"]") == .default)
        // One part garbage, the other valid: only the garbage part falls back.
        let mixed = ReaderStatsSettings.decode(
            panelJSON: "garbage", lineJSON: "{\"enabled\":false,\"stats\":[\"book_percent\"]}")
        #expect(mixed.panel == ReaderStatsSettings.default.panel)
        #expect(!mixed.lineEnabled)
        #expect(mixed.line == [.bookPercent])
    }

    @Test func emptyPanelStaysEmpty() {
        let s = ReaderStatsSettings.decode(panelJSON: "[]", lineJSON: nil)
        #expect(s.panel.isEmpty)
        #expect(s.line == ReaderStatsSettings.default.line)
    }

    @Test func lineDisabledRoundTrips() {
        let s = ReaderStatsSettings(panel: [], lineEnabled: false, line: [])
        let back = ReaderStatsSettings.decode(panelJSON: s.encodedPanelJSON(), lineJSON: s.encodedLineJSON())
        #expect(back == s)
        #expect(!back.lineEnabled)
    }
}
