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

/// Full-screen reader presented over the library: system navigation bar as chrome
/// (toggled by a center tap), loading and error states, resume-point saving.
struct ReaderScreen: View {
    @State private var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(book: BookRecord, environment: AppEnvironment) {
        _model = State(initialValue: ReaderViewModel(bookID: book.id, title: book.title, environment: environment))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            close()
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
                .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
                // The navigator isn't a scroll view SwiftUI can see, so the bar would stay in
                // its transparent edge state over text; force the system material.
                .toolbarBackground(.visible, for: .navigationBar)
                .statusBarHidden(!chromeVisible)
                .animation(.default, value: chromeVisible)
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                let model = model
                Task { await model.flush() }
            }
        }
        .onDisappear {
            let model = model
            Task { await model.close() }
        }
    }

    /// Chrome is always visible unless a book is on screen.
    private var chromeVisible: Bool {
        if case .ready = model.state { return model.isChromeVisible }
        return true
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
