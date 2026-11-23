import Combine
import GRDB
import GRDBQuery
import Persistence
import SwiftUI
import UIKit

/// What the editor should focus when it opens.
enum HighlightEditorFocus: Equatable {
    case color, note
}

/// Which highlight the editor shows (`ReaderViewModel.editingHighlight`).
struct HighlightEditorTarget: Identifiable, Equatable {
    let id: String
    var focus: HighlightEditorFocus?
}

struct HighlightByIDRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: HighlightRecord? { nil }
    var highlightID: String

    func fetch(_ db: Database) throws -> HighlightRecord? {
        try HighlightRequests.highlight(id: highlightID).fetchOne(db)
    }
}

struct HighlightTagsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [TagRecord] { [] }
    var highlightID: String

    func fetch(_ db: Database) throws -> [TagRecord] {
        try TagRequests.tags(forHighlightID: highlightID).fetchAll(db)
    }
}

struct AllTagsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [TagRecord] { [] }

    func fetch(_ db: Database) throws -> [TagRecord] {
        try TagRequests.all().fetchAll(db)
    }
}

/// Tap on a highlight (SPEC §3): color, style, note, tags, copy, delete. Every change is a DB
/// write; the reader's observation re-applies the decorations, so they update live.
/// A sheet rather than a popover at `event.rect`: on iPhone the popover adapts to a sheet anyway.
struct HighlightEditorSheet: View {
    let model: ReaderViewModel
    let target: HighlightEditorTarget

    @Query<HighlightByIDRequest> private var highlight: HighlightRecord?
    @Query<HighlightTagsRequest> private var tags: [TagRecord]
    @Query<AllTagsRequest> private var allTags: [TagRecord]
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var noteLoaded = false
    @State private var newTag = ""
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @FocusState private var noteFocused: Bool

    init(model: ReaderViewModel, target: HighlightEditorTarget) {
        self.model = model
        self.target = target
        _highlight = Query(constant: HighlightByIDRequest(highlightID: target.id))
        _tags = Query(constant: HighlightTagsRequest(highlightID: target.id))
        _allTags = Query(constant: AllTagsRequest())
    }

    var body: some View {
        NavigationStack {
            Group {
                if let highlight {
                    form(highlight)
                } else {
                    ContentUnavailableView("Highlight deleted", systemImage: "highlighter")
                }
            }
            .navigationTitle("Highlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onChange(of: highlight?.note, initial: true) { _, stored in
            // Load the stored note once; afterwards the field is the source of truth.
            guard !noteLoaded, let stored else { return }
            note = stored
            noteLoaded = true
            if target.focus == .note { noteFocused = true }
        }
        .task(id: note) {
            // Debounced note save; only real edits bump updated_at.
            guard noteLoaded, let stored = highlight?.note, note != stored else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await saveNote()
        }
        .onDisappear {
            let model = model, id = target.id, note = note
            guard noteLoaded, let stored = highlight?.note, note != stored else { return }
            Task { try? await model.database.updateHighlight(id: id, note: note) }
        }
    }

    private func form(_ highlight: HighlightRecord) -> some View {
        Form {
            Section {
                Text(highlight.quoteExact)
                    .font(.body.italic())
                    .lineLimit(6)
                    .textSelection(.enabled)
            }

            Section("Color") {
                HStack(spacing: 16) {
                    ForEach(HighlightColor.allCases, id: \.self) { color in
                        swatch(color, selected: highlight.highlightColor == color)
                    }
                }
                .frame(maxWidth: .infinity)
                Picker("Style", selection: Binding(
                    get: { highlight.highlightStyle },
                    set: { style in write { try await $0.updateHighlight(id: highlight.id, style: style) } }
                )) {
                    Text("Highlight").tag(HighlightStyle.highlight)
                    Text("Underline").tag(HighlightStyle.underline)
                }
                .pickerStyle(.segmented)
            }

            Section("Note") {
                TextField("Add a note", text: $note, axis: .vertical)
                    .lineLimit(3 ... 8)
                    .focused($noteFocused)
            }

            Section("Tags") {
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(tags) { tag in
                                tagChip(tag, highlightID: highlight.id)
                            }
                        }
                    }
                }
                TextField("Add a tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { addTag(newTag, to: highlight.id) }
                ForEach(suggestions) { tag in
                    Button {
                        addTag(tag.name ?? "", to: highlight.id)
                    } label: {
                        Label(tag.name ?? "", systemImage: "tag")
                    }
                }
            }

            Section {
                Button("Copy Quote", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = highlight.quoteExact
                }
                Button("Delete Highlight", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
                .confirmationDialog("Delete this highlight?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        write { try await $0.softDeleteHighlight(id: highlight.id) }
                        dismiss()
                    }
                }
            }
        }
    }

    private func swatch(_ color: HighlightColor, selected: Bool) -> some View {
        Button {
            write { try await $0.updateHighlight(id: target.id, color: color) }
            model.rememberHighlightColor(color)
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 34, height: 34)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.footnote.bold())
                            .foregroundStyle(.black.opacity(0.7))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tagChip(_ tag: TagRecord, highlightID: String) -> some View {
        HStack(spacing: 4) {
            Text(tag.name ?? "")
            Button {
                write { try await $0.removeTag(tagID: tag.id, fromHighlight: highlightID) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove tag \(tag.name ?? "")")
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    /// Existing tags matching what's typed, not already on this highlight.
    private var suggestions: [TagRecord] {
        let typed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let applied = Set(tags.map(\.id))
        return allTags
            .filter { !applied.contains($0.id) && ($0.name ?? "").localizedCaseInsensitiveContains(typed) }
            .prefix(5)
            .map { $0 }
    }

    private func addTag(_ name: String, to highlightID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newTag = ""
        write { try await $0.addTag(name: trimmed, toHighlight: highlightID) }
    }

    private func saveNote() async {
        do {
            try await model.database.updateHighlight(id: target.id, note: note)
        } catch {
            errorMessage = "The note couldn't be saved. \(error.localizedDescription)"
        }
    }

    private func write(_ action: @escaping @Sendable (AppDatabase) async throws -> Void) {
        let database = model.database
        Task {
            do {
                try await action(database)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
