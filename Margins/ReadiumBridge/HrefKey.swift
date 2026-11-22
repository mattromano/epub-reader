import Foundation
@preconcurrency import ReadiumShared

/// The one string form of a resource href shared by the word index (`dim_chapter.href`) and
/// the lookup from a navigator `Locator`.
///
/// The navigator builds locators from `link.url()` (already `.normalized`) and may add a
/// fragment; stored or restored locators may not be normalized. Normalizing and dropping the
/// fragment makes `key(link.url())` and `key(locator.href)` identical for the same resource,
/// the same comparison Readium's own `firstIndexWithHREF` makes.
enum HrefKey {
    nonisolated static func key(_ url: some URLConvertible) -> String {
        url.anyURL.normalized.removingFragment().string
    }
}
