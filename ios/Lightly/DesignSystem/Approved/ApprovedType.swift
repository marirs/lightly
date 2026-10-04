import SwiftUI
import UIKit

/// Type of the approved design: SF at the prototype's point sizes, scaled with the person's text
/// size, on the prototype's 1.35 line height.
///
/// The prototype multiplies every font size by one factor for large text (`--ts`, ×1.24).
/// Approved mapping (owner decision, 2026-10-04): the prototype's "large" is iOS XXL. Every size is
/// multiplied by one factor that depends only on the Dynamic Type setting:
/// - "Large" (the iOS default): ×1, the prototype's sizes (as before, see `scaledSize`);
/// - Default to XXL: rises with Apple's body-text curve, rescaled so it reaches exactly ×1.24 at XXL
///   (smaller settings shrink along the same rescaled curve);
/// - above XXL (XXXL, AX1–AX5): Apple's body curve continued from ×1.24, so text keeps growing.
/// Apple's curve alone gave ×1.18 at XXL for 13 pt text, so notes wrapped at different words.
enum ApprovedType {

    /// CSS `line-height: 1.35` on `.dv`.
    static let lineHeightMultiple: CGFloat = 1.35

    /// The prototype's large-text factor (`--ts`), matched at `approvedLargeSize`.
    static let approvedLargeFactor: CGFloat = 1.24
    static let approvedLargeSize: DynamicTypeSize = .xxLarge

    static func scaledSize(_ pointSize: CGFloat, for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        // Default-size text stays exactly as it was: UIFontMetrics, which snaps some sizes to the
        // pixel grid (12.5 pt -> 12.667 pt at 3x). Whether to drop that snapping is a separate
        // owner decision; the approved mapping covers only the larger settings.
        if dynamicTypeSize == .large {
            let traits = UITraitCollection(preferredContentSizeCategory: .large)
            return UIFontMetrics(forTextStyle: .body).scaledValue(for: pointSize, compatibleWith: traits)
        }
        return pointSize * scaleFactor(for: dynamicTypeSize)
    }

    /// One factor for every size, as in the prototype. Monotonic in the setting because Apple's
    /// body curve is, and continuous at XXL where both pieces equal `approvedLargeFactor`.
    static func scaleFactor(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        // Both anchors are exact, not computed from UIFontMetrics.
        if dynamicTypeSize == .large { return 1 }
        if dynamicTypeSize == approvedLargeSize { return approvedLargeFactor }
        let system = systemBodyFactor(for: dynamicTypeSize)
        let systemAtLarge = systemBodyFactor(for: approvedLargeSize)
        if dynamicTypeSize < approvedLargeSize {
            return 1 + (system - 1) * (approvedLargeFactor - 1) / (systemAtLarge - 1)
        }
        return system * approvedLargeFactor / systemAtLarge
    }

    /// Apple's Dynamic Type curve for body text, as a factor of its size at "Large" (17 pt).
    private static func systemBodyFactor(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let bodyAtLarge: CGFloat = 17
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: bodyAtLarge, compatibleWith: traits) / bodyAtLarge
    }

    static func uiFont(size: CGFloat, weight: Font.Weight) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight.uiFontWeight)
    }
}

extension Font.Weight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

/// Applies an approved text style: the scaled size, and the CSS line box (half the extra leading
/// above and below, the rest between lines), so text sits where the prototype puts it.
struct ApprovedTextStyle: ViewModifier {
    let pointSize: CGFloat
    let weight: Font.Weight
    /// CSS `letter-spacing`, in em.
    let trackingEm: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let size = ApprovedType.scaledSize(pointSize, for: dynamicTypeSize)
        let natural = ApprovedType.uiFont(size: size, weight: weight).lineHeight
        let extraLeading = max(0, size * ApprovedType.lineHeightMultiple - natural)
        content
            .font(.system(size: size, weight: weight))
            .tracking(size * trackingEm)
            .lineSpacing(extraLeading)
            .padding(.vertical, extraLeading / 2)
    }
}

extension View {
    /// The approved text style at `pointSize` (the prototype's px at text size Large).
    func approvedText(_ pointSize: CGFloat, weight: Font.Weight = .regular, trackingEm: CGFloat = 0) -> some View {
        modifier(ApprovedTextStyle(pointSize: pointSize, weight: weight, trackingEm: trackingEm))
    }
}
