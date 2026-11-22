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

struct TOCSheet: View {
    let model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var failedToJump = false

    var body: some View {
        NavigationStack {
            Group {
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
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't go to that section.", isPresented: $failedToJump) {
                Button("OK", role: .cancel) {}
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
