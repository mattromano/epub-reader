import Metrics
import SwiftUI

/// The reader's bottom chrome (shown on a center tap): chapter and %, a large scrubber, and the
/// live stats grid configured in Settings → Reader Stats (reader-stats design).
struct ReaderStatsPanel: View {
    let progression: Double
    let chapterTitle: String?
    let stats: [ReaderStatValue]
    /// Position while dragging; nil when the bar follows the reading position.
    @Binding var scrubValue: Double?
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // While dragging, the chapter title would be stale, so show only the target %.
                if scrubValue == nil, let chapterTitle, !chapterTitle.isEmpty {
                    Text(chapterTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("\(ProgressScrubber.percent(scrubValue ?? progression))%")
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            ProgressScrubber(progression: progression, scrubValue: $scrubValue, onSeek: onSeek)

            if !stats.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(stats) { value in
                        Label(value.text, systemImage: value.stat.symbolName)
                            .font(.subheadline)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// A full-width progress bar that's easy to grab: 8 pt track, 28 pt thumb, 44 pt hit area.
/// Drag to pick a spot (seeks on release); a tap seeks straight there.
struct ProgressScrubber: View {
    let progression: Double
    @Binding var scrubValue: Double?
    let onSeek: (Double) -> Void

    private static let thumb: CGFloat = 28
    private static let track: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let shown = Self.clamp(scrubValue ?? progression)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: Self.track)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(Self.track, width * shown), height: Self.track)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: (width - Self.thumb) * shown)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        scrubValue = Self.value(at: drag.location.x, width: width)
                    }
                    .onEnded { drag in
                        let target = Self.value(at: drag.location.x, width: width)
                        scrubValue = target
                        onSeek(target)
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Position in book")
        .accessibilityValue("\(Self.percent(scrubValue ?? progression)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.01
            let current = scrubValue ?? progression
            switch direction {
            case .increment: onSeek(Self.clamp(current + step))
            case .decrement: onSeek(Self.clamp(current - step))
            @unknown default: break
            }
        }
    }

    static func percent(_ progression: Double) -> Int {
        Int((clamp(progression) * 100).rounded())
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Maps a touch x to 0...1, measured along the thumb's travel so the ends are reachable.
    private static func value(at x: CGFloat, width: CGFloat) -> Double {
        let travel = width - thumb
        guard travel > 0 else { return 0 }
        return clamp(Double((x - thumb / 2) / travel))
    }
}

/// The always-on line under the page while the chrome is hidden ("12 min left · 260 wpm").
struct ReaderStatsLine: View {
    let stats: [ReaderStatValue]

    var body: some View {
        Text(stats.map(\.text).joined(separator: " · "))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityLabel(stats.map(\.text).joined(separator: ", "))
    }
}

extension ReaderStat {
    /// SF Symbol shown next to the stat in the tap panel.
    var symbolName: String {
        switch self {
        case .chapterTimeLeft: "hourglass"
        case .bookTimeLeft: "book.closed"
        case .bookPercent: "percent"
        case .sessionTime: "timer"
        case .sessionWPM: "speedometer"
        case .wpmVsUsual: "chart.line.uptrend.xyaxis"
        case .sessionWords: "text.word.spacing"
        case .sessionPages: "book.pages"
        case .pagesPerMinute: "arrow.forward.circle"
        case .todayVsGoal: "target"
        }
    }
}
