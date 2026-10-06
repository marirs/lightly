import SwiftUI
import UIKit

/// Multi-line approved text that breaks lines where the approved reference does.
///
/// The reference is drawn by Chromium, which breaks each line at the last word that fits. SwiftUI
/// `Text` uses UIKit's standard line-break strategy, which also pushes a word down so the last line
/// is never a single word ("…no empty / corners show." where the reference has "…no empty corners
/// / show."). SwiftUI has no setting for that, so this draws the text itself with
/// `lineBreakStrategy = []`. Size, weight, colour and the 1.35 line box are `ApprovedTextStyle`'s,
/// so it looks the same apart from those breaks; VoiceOver reads it as static text.
struct ApprovedParagraph: View {
    let text: String
    let pointSize: CGFloat
    var weight: Font.Weight = .regular
    let colour: Color
    /// Letter spacing in em (the preset name: −0.01 em).
    var trackingEm: CGFloat = 0
    /// The font's own line height instead of the approved 1.35 line box (the preset name, which `Text` drew so).
    var naturalLineHeight = false
    /// Set on the drawing view itself, so UI tests find it by identifier.
    var identifier: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let size = ApprovedType.scaledSize(pointSize, for: dynamicTypeSize)
        let font = ApprovedType.uiFont(size: size, weight: weight)
        // As `ApprovedTextStyle`: the extra leading goes between lines and half above and below.
        let extraLeading = naturalLineHeight ? 0 : max(0, size * ApprovedType.lineHeightMultiple - font.lineHeight)
        ReferenceLineBreakingLabel(text: text, font: font, colour: UIColor(colour), lineSpacing: extraLeading, kern: trackingEm * size, identifier: identifier)
            .padding(.vertical, extraLeading / 2)
    }
}

struct ReferenceLineBreakingLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    let colour: UIColor
    let lineSpacing: CGFloat
    var kern: CGFloat = 0
    var identifier: String?

    func makeUIView(context: Context) -> ParagraphDrawingView { ParagraphDrawingView() }

    func updateUIView(_ view: ParagraphDrawingView, context: Context) {
        view.attributedText = Self.referenceText(text, font: font, colour: colour, lineSpacing: lineSpacing, kern: kern)
        view.accessibilityIdentifier = identifier
    }

    /// The drawn text: word wrapping with no line-break strategy (the point of this view: no orphan push-out, nor any
    /// other adjustment), so each line breaks at the last word that fits, as the reference does. Shared with the tests.
    static func referenceText(_ text: String, font: UIFont, colour: UIColor, lineSpacing: CGFloat, kern: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph, .kern: kern])
    }

    /// The text's own fractional layout height, as SwiftUI `Text` reports it (a `UILabel` rounds
    /// up to whole points, which moved everything below a note down by up to 1 pt).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ParagraphDrawingView, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let bounds = view.layoutBounds(width: width)
        return CGSize(width: proposal.width ?? bounds.width, height: bounds.height)
    }
}

/// Draws the paragraph from the top of its bounds. A `UILabel` would centre it vertically and drop a
/// line whenever its fractional height is a hair short of what it wants.
final class ParagraphDrawingView: UIView {
    var attributedText = NSAttributedString() {
        didSet {
            guard attributedText != oldValue else { return }
            accessibilityLabel = attributedText.string
            setNeedsDisplay()
        }
    }

    private static let drawingOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func layoutBounds(width: CGFloat) -> CGRect {
        attributedText.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: Self.drawingOptions, context: nil)
    }

    override func draw(_ rect: CGRect) {
        attributedText.draw(with: CGRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude),
                            options: Self.drawingOptions, context: nil)
    }
}
