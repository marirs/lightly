import SwiftUI
import UIKit

/// Type of the approved design: SF at the prototype's point sizes, scaled with the person's text
/// size, on the prototype's 1.35 line height.
///
/// The prototype multiplies every font size by one factor for large text (`--ts`, ×1.24).
/// Natively the factor comes from Dynamic Type (`UIFontMetrics` for the body style), so every
/// size up to AX5 is supported, and at "Large" (the iOS default) sizes are exactly the
/// prototype's.
enum ApprovedType {

    /// CSS `line-height: 1.35` on `.dv`.
    static let lineHeightMultiple: CGFloat = 1.35

    static func scaledSize(_ pointSize: CGFloat, for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: pointSize, compatibleWith: traits)
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
