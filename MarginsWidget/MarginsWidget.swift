import ImageIO
import SwiftUI
import WidgetData
import WidgetKit

/// Home Screen and Lock Screen widget (PLAN M6). Reads `widget_snapshot.json` from the App
/// Group container; never opens the database.
@main
struct MarginsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ReadingWidget()
    }
}

struct ReadingWidget: Widget {
    static let kind = "MarginsReading"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ReadingProvider()) { entry in
            ReadingWidgetView(entry: entry)
        }
        .configurationDisplayName("Reading")
        .description("Your streak, today's minutes and the book you're reading.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct ReadingEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written a snapshot.
    let state: WidgetDisplayState?
    let cover: CGImage?
}

struct ReadingProvider: TimelineProvider {
    static let appGroup = "group.com.mattromano.margins"

    func placeholder(in context: Context) -> ReadingEntry {
        ReadingEntry(date: .now, state: Self.sample, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadingEntry) -> Void) {
        let entry = context.isPreview ? placeholder(in: context) : entries(now: .now).first!
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingEntry>) -> Void) {
        completion(Timeline(entries: entries(now: .now), policy: .atEnd))
    }

    /// Now, plus one entry when the reading day rolls over (today's minutes reset and the
    /// streak goes "at risk"). The app reloads the timeline after every session.
    private func entries(now: Date) -> [ReadingEntry] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup),
              let snapshot = WidgetSnapshot.read(from: container) else {
            return [ReadingEntry(date: now, state: nil, cover: nil)]
        }
        let cover = snapshot.continueReading?.coverRelpath.flatMap {
            Self.thumbnail(at: container.appendingPathComponent($0), maxPixels: 300)
        }
        let rollover = snapshot.nextDayStart(after: now)
        return [
            ReadingEntry(date: now, state: snapshot.display(at: now), cover: cover),
            ReadingEntry(date: rollover, state: snapshot.display(at: rollover), cover: cover),
        ]
    }

    /// Downsampled cover, so the widget stays well inside its memory limit.
    private static func thumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static let sample = WidgetDisplayState(
        todayMinutes: 18, goalMinutes: 30, goalProgress: 0.6, currentStreak: 12, streakIsAtRisk: false,
        continueReading: .init(bookID: "", title: "Middlemarch", authors: "George Eliot", coverRelpath: nil,
                               percentComplete: 0.42, bookMinutesLeft: 312))
}

// MARK: - Views

struct ReadingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReadingEntry

    var body: some View {
        Group {
            if let state = entry.state {
                switch family {
                case .systemMedium: MediumView(state: state, cover: entry.cover)
                case .accessoryRectangular: RectangularView(state: state)
                default: SmallView(state: state)
                }
            } else {
                EmptyStateView()
            }
        }
        .widgetURL(entry.state?.continueReading.map { WidgetLink.openBook($0.bookID) })
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

enum WidgetFormat {
    static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total) min" }
        let rest = total % 60
        return rest == 0 ? "\(total / 60) h" : "\(total / 60) h \(rest) m"
    }

    static func streak(_ state: WidgetDisplayState) -> String {
        state.currentStreak == 1 ? "1 day" : "\(state.currentStreak) days"
    }

    static func today(_ state: WidgetDisplayState) -> String {
        if let goal = state.goalMinutes {
            return "\(Int(state.todayMinutes.rounded()))/\(Int(goal.rounded())) min"
        }
        return minutes(state.todayMinutes)
    }
}

private struct GoalRing: View {
    let progress: Double
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct SmallView: View {
    let state: WidgetDisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: state.streakIsAtRisk ? "flame" : "flame.fill")
                    .foregroundStyle(.orange)
                Text(WidgetFormat.streak(state))
                    .font(.headline)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(WidgetFormat.today(state))
                        .font(.subheadline.bold())
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                GoalRing(progress: state.goalProgress ?? 0, lineWidth: 7)
                    .frame(width: 44, height: 44)
            }
            if state.streakIsAtRisk {
                Text("Read today to keep it")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MediumView: View {
    let state: WidgetDisplayState
    let cover: CGImage?

    var body: some View {
        HStack(spacing: 14) {
            if let book = state.continueReading {
                Group {
                    if let cover {
                        Image(decorative: cover, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 70, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue reading")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !book.authors.isEmpty {
                        Text(book.authors)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(progressText(book))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill").foregroundStyle(.orange)
                        Text("\(WidgetFormat.streak(state)) · \(WidgetFormat.today(state))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
            } else {
                SmallView(state: state)
            }
        }
    }

    private func progressText(_ book: WidgetSnapshot.ContinueReading) -> String {
        var parts: [String] = []
        if let pct = book.percentComplete { parts.append("\(Int((pct * 100).rounded()))%") }
        if let left = book.bookMinutesLeft { parts.append("\(WidgetFormat.minutes(left)) left") }
        return parts.joined(separator: " · ")
    }
}

private struct RectangularView: View {
    let state: WidgetDisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(WidgetFormat.streak(state), systemImage: state.streakIsAtRisk ? "flame" : "flame.fill")
                .font(.headline)
                .widgetAccentable()
            Text("Today \(WidgetFormat.today(state))")
                .font(.caption)
                .monospacedDigit()
            if let book = state.continueReading {
                Text(book.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .font(.title2)
            Text("Open Margins to start reading")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}
