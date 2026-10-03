import SwiftUI

/// Typographic scale for Lightly.
///
/// Every style is built on a `Font.TextStyle` so that Dynamic Type scaling works
/// without additional work at the call site (V1 acceptance criteria require
/// Dynamic Type support). Fixed point sizes are deliberately avoided.
///
/// The brand voice is quiet: light weights, generous tracking on the wordmark,
/// and no display faces heavier than `.regular` outside of primary actions.
enum LightlyTypography {

    /// The "Lightly" wordmark on the launch screen.
    static let wordmark = Font.system(.largeTitle, design: .default).weight(.light)

    /// The tagline: "See it as you remember it."
    static let tagline = Font.system(.title3, design: .default).weight(.regular)

    /// Sheet and screen titles, e.g. "Choose a photo".
    static let title = Font.system(.title3, design: .default).weight(.semibold)

    /// Supporting copy beneath a title.
    static let subtitle = Font.system(.footnote, design: .default).weight(.regular)

    /// Primary row labels, e.g. "Camera", "Photo Library".
    static let rowTitle = Font.system(.body, design: .default).weight(.medium)

    /// Secondary row detail, e.g. "Take a new photo".
    static let rowSubtitle = Font.system(.footnote, design: .default).weight(.regular)

    /// The label inside a primary action button, e.g. "Develop".
    static let actionPrimary = Font.system(.body, design: .default).weight(.semibold)

    /// Small captions and the swipe affordance label.
    static let caption = Font.system(.caption, design: .default).weight(.regular)
}
