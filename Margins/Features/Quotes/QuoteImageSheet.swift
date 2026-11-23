import Persistence
import SwiftUI

/// Quote-as-image themes (PLAN M4).
enum QuoteImageTheme: String, CaseIterable, Identifiable {
    case paper, night, tint

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .paper: "Paper"
        case .night: "Night"
        case .tint: "Color"
        }
    }
}

/// The card that's rendered to an image. Fixed width, so the image is the same on every device.
struct QuoteImageCard: View {
    let quote: QuoteItem
    let theme: QuoteImageTheme

    static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "quote.opening")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(accent)
            Text(quote.highlight.quoteExact)
                .font(.system(size: quoteSize, weight: .regular, design: .serif))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.bookTitle)
                    .font(.system(size: 15, weight: .semibold))
                if !quote.bookAuthors.isEmpty {
                    Text(quote.bookAuthors)
                        .font(.system(size: 14))
                }
            }
            .foregroundStyle(foreground.opacity(0.75))
            Text("Margins")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(background)
    }

    /// Long quotes get a smaller type size so the card stays shareable.
    private var quoteSize: CGFloat {
        switch quote.highlight.quoteExact.count {
        case ..<140: 24
        case ..<400: 19
        default: 15
        }
    }

    private var tint: Color { quote.highlight.highlightColor.color }

    private var background: Color {
        switch theme {
        case .paper: Color(red: 0.98, green: 0.96, blue: 0.91)
        case .night: Color(red: 0.11, green: 0.11, blue: 0.13)
        case .tint: tint.mix(with: .white, by: 0.55)
        }
    }

    private var foreground: Color {
        theme == .night ? Color(white: 0.93) : Color(white: 0.1)
    }

    private var accent: Color {
        switch theme {
        case .paper, .night: tint
        case .tint: Color(white: 0.1).opacity(0.6)
        }
    }
}

/// Pick a theme, preview, share the rendered PNG.
struct QuoteImageSheet: View {
    let quote: QuoteItem
    @AppStorage("quoteImageTheme") private var themeRaw = QuoteImageTheme.paper.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private var theme: QuoteImageTheme { QuoteImageTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(QuoteImageTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    QuoteImageCard(quote: quote, theme: theme)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 6, y: 2)

                    if let image = renderedImage {
                        ShareLink(
                            item: image,
                            preview: SharePreview(quote.bookTitle, image: image)
                        ) {
                            Label("Share Image", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding()
            }
            .navigationTitle("Quote Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    /// At least 3x, so the 360 pt card is ≥ 1080 px wide.
    private var renderedImage: Image? {
        let renderer = ImageRenderer(content: QuoteImageCard(quote: quote, theme: theme))
        renderer.scale = max(3, displayScale)
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}
