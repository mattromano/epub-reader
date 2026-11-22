@preconcurrency import ReadiumNavigator
import SwiftUI

/// The Aa sheet: a Form over Readium's `EPUBPreferencesEditor` (Preferences guide).
///
/// The editor is a plain class SwiftUI can't observe, so it's rebuilt on every render from the
/// observable `model.preferences`; each control mutates it and hands the result to
/// `model.apply(_:)`, which submits live and debounce-saves to the book.
struct PreferencesSheet: View {
    let model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var defaultSaveResult: DefaultSaveResult?

    enum DefaultSaveResult: Identifiable {
        case saved, failed
        var id: Self { self }
    }

    static let fontFamilies: [FontFamily?] = [
        nil, // Original: the publisher's font.
        .iowanOldStyle,
        .palatino,
        .georgia,
        .helveticaNeue,
        .seravek,
        .openDyslexic,
        .accessibleDfA,
        .iaWriterDuospace,
    ]

    static let themes: [Theme] = [.light, .sepia, .dark]

    var body: some View {
        NavigationStack {
            Group {
                if let editor = model.makeEditor() {
                    form(editor)
                } else {
                    ContentUnavailableView("Book not open", systemImage: "textformat.size")
                }
            }
            .navigationTitle("Reading Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(item: $defaultSaveResult) { result in
                switch result {
                case .saved:
                    Alert(
                        title: Text("Saved as Default"),
                        message: Text("Books without their own settings will open with these.")
                    )
                case .failed:
                    Alert(
                        title: Text("Couldn't Save Default"),
                        message: Text("Your settings for this book are unchanged. Try again.")
                    )
                }
            }
        }
    }

    private func form(_ editor: EPUBPreferencesEditor) -> some View {
        let commit: @MainActor () -> Void = { model.apply(editor.preferences) }
        let publisherStylesOn = editor.publisherStyles.value ?? editor.publisherStyles.effectiveValue

        return Form {
            Section {
                Picker("Theme", selection: editor.theme.binding(onSet: commit)) {
                    ForEach(Self.themes, id: \.self) { theme in
                        Text(Self.name(of: theme)).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(SwiftUI.Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section("Text") {
                Picker("Font", selection: editor.fontFamily.binding(onSet: commit)) {
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(Self.name(of: family)).tag(family)
                    }
                }
                stepperRow("Font size", editor.fontSize, commit: commit)
                stepperRow("Page margins", editor.pageMargins, commit: commit)
            }

            Section {
                Toggle("Publisher styles", isOn: editor.publisherStyles.binding(onSet: commit))
                // Readium marks lineHeight effective only once it has a value, so gate on
                // publisher styles (what actually blocks it) instead of `isEffective`.
                stepperRow("Line height", editor.lineHeight, commit: commit)
                    .disabled(publisherStylesOn)
            } footer: {
                if publisherStylesOn {
                    Text("Turn off publisher styles to change line height.")
                }
            }

            Section {
                Toggle("Scroll", isOn: editor.scroll.binding(onSet: commit))
            } footer: {
                Text("Scroll through each chapter instead of turning pages.")
            }

            Section {
                Button("Use as Default for New Books") {
                    Task {
                        defaultSaveResult = await model.useAsDefault() ? .saved : .failed
                    }
                }
                Button("Reset", role: .destructive) {
                    model.resetPreferences()
                }
            } footer: {
                Text("Reset returns this book to your default settings.")
            }
        }
    }

    private func stepperRow(
        _ title: String,
        _ preference: AnyRangePreference<Double>,
        commit: @escaping @MainActor () -> Void
    ) -> some View {
        let current = preference.value ?? preference.effectiveValue
        return Stepper {
            HStack {
                Text(title)
                Spacer()
                Text(preference.format(value: current))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } onIncrement: {
            preference.increment()
            commit()
        } onDecrement: {
            preference.decrement()
            commit()
        }
    }

    private static func name(of theme: Theme) -> String {
        switch theme {
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        }
    }

    private static func name(of family: FontFamily?) -> String {
        guard let family else { return "Original" }
        switch family {
        case .iowanOldStyle: return "Iowan Old Style"
        case .helveticaNeue: return "Helvetica Neue"
        case .iaWriterDuospace: return "iA Writer Duospace"
        case .accessibleDfA: return "Accessible DfA"
        default: return family.rawValue
        }
    }
}

extension AnyPreference {
    /// A SwiftUI binding over a Readium preference (Preferences guide). Shows the user's value,
    /// falling back to the effective one. The editor is main-thread only (it asserts so), and
    /// SwiftUI reads and writes bindings on the main thread.
    @MainActor
    func binding(onSet: @escaping @MainActor () -> Void) -> Binding<Value> {
        Binding(
            get: { [self] in value ?? effectiveValue },
            set: { [self] newValue in
                MainActor.assumeIsolated {
                    set(newValue)
                    onSet()
                }
            }
        )
    }
}
