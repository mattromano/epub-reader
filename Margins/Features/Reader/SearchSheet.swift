@preconcurrency import ReadiumShared
import SwiftUI

struct SearchSheet: View {
    let model: ReaderViewModel
    @Bindable var search: SearchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSearchFieldPresented = true
    @State private var failedToJump = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $search.query,
                    isPresented: $isSearchFieldPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search this book"
                )
                .onSubmit(of: .search) { search.submit() }
                .onChange(of: search.query) { _, newValue in
                    // Clearing the field (the ⓧ button) clears the results too.
                    if newValue.isEmpty { search.clear() }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .alert("Couldn't go to that result.", isPresented: $failedToJump) {
                    Button("OK", role: .cancel) {}
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if search.sections.isEmpty {
            switch search.phase {
            case .idle:
                ContentUnavailableView(
                    "Search This Book",
                    systemImage: "magnifyingglass",
                    description: Text("Type a word or phrase, then tap Search.")
                )
            case .searching:
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished:
                ContentUnavailableView.search(text: search.searchedQuery)
            case let .failed(message):
                ContentUnavailableView(
                    "Search Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        } else {
            results
        }
    }

    private var results: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Text(summary)
                    if search.phase == .searching {
                        ProgressView()
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if case let .failed(message) = search.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(search.sections) { section in
                Section(section.title ?? "Untitled section") {
                    ForEach(section.results) { result in
                        Button {
                            jump(to: result.locator)
                        } label: {
                            Text(SearchSnippet.attributed(result.locator.text))
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        let count = search.resultCount
        return count == 1 ? "1 result" : "\(count) results"
    }

    private func jump(to locator: Locator) {
        Task {
            if await model.go(to: .locator(locator)) {
                dismiss()
            } else {
                failedToJump = true
            }
        }
    }
}

/// A search result snippet with the match in bold and the context trimmed to stay compact.
enum SearchSnippet {
    static let contextLength = 60

    static func attributed(_ text: Locator.Text) -> AttributedString {
        let text = text.sanitized()
        var result = AttributedString()
        if let before = text.before, !before.isEmpty {
            let trimmed = before.count > contextLength ? "…" + String(before.suffix(contextLength)) : before
            result += AttributedString(trimmed)
        }
        if let highlight = text.highlight {
            var bold = AttributedString(highlight)
            bold.inlinePresentationIntent = .stronglyEmphasized
            result += bold
        }
        if let after = text.after, !after.isEmpty {
            let trimmed = after.count > contextLength ? String(after.prefix(contextLength)) + "…" : after
            result += AttributedString(trimmed)
        }
        return result
    }
}
