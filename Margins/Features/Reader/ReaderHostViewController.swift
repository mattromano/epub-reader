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
            config: EPUBNavigatorViewController.Configuration(preferences: preferences)
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
}

extension ReaderHostViewController: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        model?.locationDidChange(locator)
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
