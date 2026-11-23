import Persistence
import SwiftUI
import UIKit

/// The five highlight tints (SPEC §5.2 `fact_highlight.color`), for Readium decorations and SwiftUI.
extension HighlightColor {
    var uiColor: UIColor {
        switch self {
        case .yellow: UIColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 1)
        case .green: UIColor(red: 0.45, green: 0.80, blue: 0.35, alpha: 1)
        case .blue: UIColor(red: 0.35, green: 0.65, blue: 1.00, alpha: 1)
        case .pink: UIColor(red: 1.00, green: 0.45, blue: 0.65, alpha: 1)
        case .purple: UIColor(red: 0.70, green: 0.50, blue: 0.95, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    var displayName: String { rawValue.capitalized }
}
