@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

/// Hosts the Readium `EPUBNavigatorViewController` (per Readium's SwiftUI guide), so custom
/// editing actions can later reach this controller through the responder chain.
final class ReaderHostViewController: UIViewController {
    private let navigator: EPUBNavigatorViewController
    private weak var model: ReaderViewModel?

    init(
        publication: Publication,
        initialLocation: Locator?,
        preferences: EPUBPreferences,
        model: ReaderViewModel
    ) throws {
        navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: EPUBNavigatorViewController.Configuration(
                preferences: preferences,
                // Custom items first so Highlight is one tap away (the two-tap rule, PLAN M3).
                editingActions: [
                    EditingAction(title: "Highlight", action: #selector(highlightSelection)),
                    EditingAction(title: "Color", action: #selector(highlightSelectionChoosingColor)),
                    EditingAction(title: "Note", action: #selector(highlightSelectionWithNote)),
                ] + EditingAction.defaultActions
            )
        )
        self.model = model
        super.init(nibName: nil, bundle: nil)
        navigator.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Navigator API used by ReaderViewModel

    /// The navigator's last reported location.
    var currentLocation: Locator? {
        navigator.currentLocation
    }

    /// Applies preferences live; the navigator keeps the reading position.
    func submit(_ preferences: EPUBPreferences) {
        navigator.submitPreferences(preferences)
    }

    /// A fresh editor seeded with `preferences` (knows ranges, supported values, isEffective).
    func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        navigator.editor(of: preferences)
    }

    @discardableResult
    func go(to locator: Locator) async -> Bool {
        await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
    }

    @discardableResult
    func go(to link: Link) async -> Bool {
        await navigator.go(to: link, options: NavigatorGoOptions(animated: false))
    }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        // A tap on a highlight reaches only this callback, not the tap observer below.
        navigator.observeDecorationInteractions(inGroup: HighlightCapture.decorationGroup) { [weak self] event in
            self?.model?.didTapHighlight(id: event.decoration.id)
        }

        // Tap zones via the navigator's input observer, never SwiftUI gestures (SPEC §3).
        navigator.addObserver(.tap { [weak self] event in
            guard let self else { return false }
            let width = navigator.view.bounds.width
            guard width > 0 else { return false }
            let x = event.location.x
            if x < width / 3 {
                await navigator.goLeft(options: .animated)
            } else if x > width * 2 / 3 {
                await navigator.goRight(options: .animated)
            } else {
                model?.toggleChrome()
            }
            return true
        })
    }

    // MARK: Selection menu (EditingActions reach these through the responder chain)

    @objc func highlightSelection() {
        captureSelection(then: nil)
    }

    @objc func highlightSelectionChoosingColor() {
        captureSelection(then: .color)
    }

    @objc func highlightSelectionWithNote() {
        captureSelection(then: .note)
    }

    private func captureSelection(then focus: HighlightEditorFocus?) {
        guard let selection = navigator.currentSelection else { return }
        navigator.clearSelection()
        model?.createHighlight(from: selection.locator, openEditor: focus)
    }

    // MARK: Decorations

    /// The full list every time; the navigator diffs it (Decorations guide).
    func applyHighlightDecorations(_ decorations: [Decoration]) {
        navigator.apply(decorations: decorations, in: HighlightCapture.decorationGroup)
    }

    /// Rotation reflows the page: the resulting location change is a jump, not reading.
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        model?.markNextLocationAsJump()
    }
}

extension ReaderHostViewController: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        model?.locationDidChange(locator)
    }

    /// Internal links and programmatic `go`. Fires before the matching location change.
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        model?.didJumpToLink()
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        let message: String
        switch error {
        case .copyForbidden:
            message = "This book doesn't allow copying text."
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
