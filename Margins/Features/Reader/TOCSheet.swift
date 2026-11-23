import Persistence
@preconcurrency import ReadiumShared
import SwiftUI

/// One row of the flattened table of contents.
struct TOCEntry: Identifiable {
    /// Position in reading order (stable for a given publication).
    let id: Int
    let link: ReadiumShared.Link
    let title: String
    /// Nesting level, 0 for top-level entries.
    let depth: Int

    /// Depth-first flattening of `publication.tableOfContents()`.
    static func flatten(_ links: [ReadiumShared.Link]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        func visit(_ links: [ReadiumShared.Link], depth: Int) {
            for link in links {
                let trimmed = link.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                entries.append(TOCEntry(
                    id: entries.count,
                    link: link,
                    title: trimmed.isEmpty ? "Untitled section" : trimmed,
                    depth: depth
                ))
                visit(link.children, depth: depth + 1)
            }
        }
        visit(links, depth: 0)
        return entries
    }
}

/// Contents, Highlights and Bookmarks for the open book; tapping a row jumps there.
struct TOCSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case contents = "Contents", highlights = "Highlights", bookmarks = "Bookmarks"
        var id: String { rawValue }
    }

    let model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .contents
    @State private var failedToJump = false

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .contents: contents
                case .highlights: highlightList
                case .bookmarks: bookmarkList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't go there.", isPresented: $failedToJump) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var contents: some View {
        if model.tableOfContents.isEmpty {
            ContentUnavailableView(
                "No Table of Contents",
                systemImage: "list.bullet",
                description: Text("This book doesn't include one.")
            )
        } else {
            list
        }
    }

    @ViewBuilder
    private var highlightList: some View {
        if model.highlights.isEmpty {
            ContentUnavailableView(
                "No Highlights",
                systemImage: "highlighter",
                description: Text("Select text and tap Highlight.")
            )
        } else {
            List(model.highlights) { highlight in
                Button {
                    jump(toStored: highlight.locatorJSON)
                } label: {
                    HighlightRow(highlight: highlight)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private var bookmarkList: some View {
        if model.bookmarks.isEmpty {
            ContentUnavailableView(
                "No Bookmarks",
                systemImage: "bookmark",
                description: Text("Tap the bookmark button while reading.")
            )
        } else {
            List {
                ForEach(model.bookmarks) { bookmark in
                    Button {
                        jump(toStored: bookmark.locatorJSON)
                    } label: {
                        Label(bookmark.label ?? "Bookmark", systemImage: "bookmark")
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.bookmarks[$0].id }
                    let database = model.database
                    Task {
                        for id in ids {
                            try? await database.softDeleteBookmark(id: id)
                        }
                    }
                }
            }
        }
    }

    private func jump(toStored json: String?) {
        Task {
            if await model.go(toStoredLocator: json) {
                dismiss()
            } else {
                failedToJump = true
            }
        }
    }

    private var list: some View {
        let currentID = currentEntryID
        return ScrollViewReader { proxy in
            List(model.tableOfContents) { entry in
                Button {
                    jump(to: entry)
                } label: {
                    HStack {
                        Text(entry.title)
                            .fontWeight(entry.id == currentID ? .semibold : .regular)
                            .foregroundStyle(.primary)
                        Spacer()
                        if entry.id == currentID {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Current chapter")
                        }
                    }
                    .padding(.leading, CGFloat(min(entry.depth, 4)) * 16)
                }
                .id(entry.id)
            }
            .onAppear {
                if let currentID {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
    }

    /// The entry for the current location: matching title and resource first, then the first
    /// entry pointing into the current resource.
    private var currentEntryID: Int? {
        guard let href = model.currentHref else { return nil }
        let inResource = model.tableOfContents.filter {
            $0.link.url().removingFragment().isEquivalentTo(href)
        }
        if let title = model.currentChapterTitle,
           let match = inResource.first(where: { $0.link.title == title }) {
            return match.id
        }
        return inResource.first?.id
    }

    private func jump(to entry: TOCEntry) {
        Task {
            if await model.go(to: .link(entry.link)) {
                dismiss()
            } else {
                failedToJump = true
            }
        }
    }
}

/// A highlight in a list: color dot, quote, note, chapter.
struct HighlightRow: View {
    let highlight: HighlightRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(highlight.highlightColor.color)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.quoteExact)
                    .lineLimit(4)
                if let note = highlight.note, !note.isEmpty {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let chapter = highlight.chapterTitle, !chapter.isEmpty {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
