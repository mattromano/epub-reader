import Persistence
import SwiftUI

/// SwiftUI wrapper for `ReaderHostViewController` (Readium SwiftUI guide).
struct ReaderView: UIViewControllerRepresentable {
    let host: ReaderHostViewController

    func makeUIViewController(context: Context) -> ReaderHostViewController {
        host
    }

    func updateUIViewController(_ uiViewController: ReaderHostViewController, context: Context) {}
}

/// Full-screen reader presented over the library: system navigation and bottom bars as chrome
/// (toggled by a center tap), loading and error states, resume-point saving, and the
/// TOC / Search / Aa sheets.
struct ReaderScreen: View {
    enum ActiveSheet: String, Identifiable {
        case contents, search, preferences
        var id: String { rawValue }
    }

    @State private var model: ReaderViewModel
    @State private var activeSheet: ActiveSheet?
    /// Scrubber position while the user is dragging; nil when it follows the reading position.
    @State private var scrubValue: Double?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// `initialLocatorJSON` opens at that spot (a highlight) instead of the saved position.
    init(book: BookRecord, environment: AppEnvironment, initialLocatorJSON: String? = nil) {
        _model = State(initialValue: ReaderViewModel(
            bookID: book.id, title: book.title, environment: environment,
            initialLocatorJSON: initialLocatorJSON
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
                .toolbar(bottomBarVisible ? .visible : .hidden, for: .bottomBar)
                // The navigator isn't a scroll view SwiftUI can see, so the bars would stay in
                // their transparent edge state over text; force the system material.
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(.visible, for: .bottomBar)
                .statusBarHidden(!chromeVisible)
                .animation(.default, value: chromeVisible)
                .sheet(item: editingHighlight) { target in
                    HighlightEditorSheet(model: model, target: target)
                        .presentationDetents([.medium, .large])
                }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            let model = model
            switch phase {
            case .background:
                model.didEnterBackground()
                Task { await model.flush() }
            case .active:
                model.didBecomeActive()
            default:
                break
            }
        }
        .onDisappear {
            let model = model
            Task { await model.close() }
        }
    }

    private var editingHighlight: Binding<HighlightEditorTarget?> {
        Binding(get: { model.editingHighlight }, set: { model.editingHighlight = $0 })
    }

    /// Chrome is always visible unless a book is on screen.
    private var chromeVisible: Bool {
        if case .ready = model.state { return model.isChromeVisible }
        return true
    }

    /// The scrubber only exists while a book is on screen.
    private var bottomBarVisible: Bool {
        if case .ready = model.state { return model.isChromeVisible }
        return false
    }

    private var isReady: Bool {
        if case .ready = model.state { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                close()
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        if isReady {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    let model = model
                    Task { await model.toggleBookmark() }
                } label: {
                    let marked = model.currentBookmark != nil
                    Label(marked ? "Remove Bookmark" : "Add Bookmark",
                          systemImage: marked ? "bookmark.fill" : "bookmark")
                }
                Button {
                    activeSheet = .contents
                } label: {
                    Label("Contents", systemImage: "list.bullet")
                }
                if model.isSearchable {
                    Button {
                        activeSheet = .search
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                if !model.isFixedLayout {
                    Button {
                        activeSheet = .preferences
                    } label: {
                        Label("Reading Settings", systemImage: "textformat.size")
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                scrubber
            }
        }
    }

    private var scrubber: some View {
        let shown = scrubValue ?? model.currentProgression
        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { scrubValue ?? model.currentProgression },
                    set: { scrubValue = $0 }
                ),
                in: 0 ... 1
            ) { editing in
                if !editing, let target = scrubValue {
                    seek(to: target)
                }
            }
            .accessibilityLabel("Position in book")
            .accessibilityValue("\(Self.percent(shown)) percent")

            Text(progressLabel(shown))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func progressLabel(_ progression: Double) -> String {
        let percent = "\(Self.percent(progression))%"
        // While dragging, the chapter title would be stale, so show only the target percentage.
        guard scrubValue == nil, let chapter = model.currentChapterTitle, !chapter.isEmpty else {
            return percent
        }
        return "\(chapter) · \(percent)"
    }

    private static func percent(_ progression: Double) -> Int {
        Int((min(max(progression, 0), 1) * 100).rounded())
    }

    private func seek(to progression: Double) {
        let model = model
        Task {
            await model.seek(toProgression: progression)
            // Hand the slider back to the reading position once the jump has landed.
            scrubValue = nil
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .contents:
            TOCSheet(model: model)
                .presentationDetents([.medium, .large])
        case .search:
            if let search = model.search {
                SearchSheet(model: model, search: search)
                    .presentationDetents([.medium, .large])
            }
        case .preferences:
            PreferencesSheet(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Can't open this book", systemImage: "book.closed")
            } description: {
                Text(message)
            } actions: {
                Button("Close") { close() }
            }
        case let .ready(host):
            ReaderView(host: host)
                .ignoresSafeArea()
        }
    }

    private func close() {
        let model = model
        // Unstructured task: the save outlives the dismissed view.
        Task { await model.close() }
        dismiss()
    }
}
