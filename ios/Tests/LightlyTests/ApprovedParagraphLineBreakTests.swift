import UIKit
import XCTest
@testable import Lightly

/// M4 (preset names): the name row breaks lines where the approved reference (Chromium) does, at the last word that
/// fits, not with UIKit's standard strategy, which pushes a word down so a paragraph never ends on one word.
final class ApprovedParagraphLineBreakTests: XCTestCase {
    private let presetName = "Landscape 15 - Winter Wonderland"
    private let font = ApprovedType.uiFont(size: 17, weight: .semibold)

    private func lines(_ text: NSAttributedString, width: CGFloat) -> [String] {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        var result: [String] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, range, _ in
            let chars = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            result.append((text.string as NSString).substring(with: chars).trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    /// The reference's rule: each line takes as many words as fit.
    private func greedy(width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> [String] {
        var result: [String] = [], current = ""
        for word in presetName.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if current.isEmpty || NSAttributedString(string: candidate, attributes: attributes).size().width <= width { current = candidate }
            else { result.append(current); current = word }
        }
        return result + [current]
    }

    func testTheNameBreaksAtTheLastWordThatFitsAtEveryWidth() {
        let reference = ReferenceLineBreakingLabel.referenceText(presetName, font: font, colour: .black, lineSpacing: 0, kern: -0.17)
        let attributes = reference.attributes(at: 0, effectiveRange: nil)
        var differsFromStandard = false
        for width in stride(from: CGFloat(140), through: 320, by: 0.5) {
            XCTAssertEqual(lines(reference, width: width), greedy(width: width, attributes: attributes), "width \(width)")
            let standard = NSMutableAttributedString(attributedString: reference)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineBreakStrategy = .standard
            standard.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: standard.length))
            if lines(standard, width: width) != lines(reference, width: width) { differsFromStandard = true }
        }
        // The case in the review: the standard strategy gives "Landscape 15 - / Winter Wonderland" at some width.
        XCTAssertTrue(differsFromStandard, "the standard strategy should differ somewhere, or the test proves nothing")
    }
}
