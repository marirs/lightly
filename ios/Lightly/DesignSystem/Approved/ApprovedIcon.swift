import SwiftUI

/// The approved design's line icons, drawn from the prototype's own 24-unit SVG geometry
/// (`ICON` in `docs/ui/app/app.js`): 1.6-unit round strokes that scale with the icon.
///
/// Drawn natively from the same path data rather than substituted with SF Symbols, whose shapes
/// and weights differ visibly at these sizes.
enum ApprovedIcon: String, CaseIterable, Sendable {
    case more, close, back, chevron, photo, camera, grip, trash, check
    // Editor (slice 2): top bar, tool navigation, Develop and the save sheets.
    case undo, redo, compare, develop, background, portrait, edit, effects, watermark, border, star, info, warn, share
    // Background (slice 3): refine brush, add, bokeh shapes.
    case brush, erase, plus, circle, hex, heart, starShape
    /// Effects › Selective Colour (owner-approved proposal 2026-10-05): eyedropper.
    case picker
    // Edit (slice 4): Rotate left/right, Flip horizontal/vertical.
    case rotl, rotr, fliph, flipv

    /// One drawing primitive in the 24×24 view box.
    enum Element: Sendable {
        case path(String, strokeWidth: CGFloat = ApprovedIcon.strokeWidth)
        /// `fill="currentColor" stroke="none"` (the filled half of Compare).
        case filledPath(String)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat, filled: Bool)
    }

    static let viewBox: CGFloat = 24
    static let strokeWidth: CGFloat = 1.6

    var elements: [Element] {
        switch self {
        case .more:
            [.circle(cx: 12, cy: 5.5, r: 1.3, filled: true), .circle(cx: 12, cy: 12, r: 1.3, filled: true), .circle(cx: 12, cy: 18.5, r: 1.3, filled: true)]
        case .close:
            [.path("M6 6l12 12M18 6L6 18")]
        case .back:
            [.path("M15 5l-7 7 7 7")]
        case .chevron:
            [.path("M9 5l7 7-7 7")]
        case .photo:
            [.rect(x: 3.5, y: 4.5, width: 17, height: 15, cornerRadius: 2.5), .circle(cx: 9, cy: 10, r: 1.8, filled: false), .path("M4 17l4.5-4.5 4 4 2.5-2.5 5 5")]
        case .camera:
            [.path("M4 8.5A2.5 2.5 0 0 1 6.5 6h1.6l1.4-2h5l1.4 2h1.6A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z"), .circle(cx: 12, cy: 12.5, r: 3.4, filled: false)]
        case .grip:
            [.path("M8 7h.01M8 12h.01M8 17h.01M16 7h.01M16 12h.01M16 17h.01", strokeWidth: 3)]
        case .trash:
            [.path("M5 7h14M9 7V5h6v2M7 7l1 13h8l1-13")]
        case .check:
            [.path("M5 12.5l4.5 4.5L19 7.5")]
        case .undo:
            [.path("M9 7H5V3"), .path("M5.5 7.5A8 8 0 1 1 4 13")]
        case .redo:
            [.path("M15 7h4V3"), .path("M18.5 7.5A8 8 0 1 0 20 13")]
        case .compare:
            [.rect(x: 4.5, y: 4.5, width: 15, height: 15, cornerRadius: 2.5), .path("M12 4.5v15"),
             .filledPath("M12 4.5h5a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5h-5z")]
        case .develop:
            [.path("M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1")]
        case .background:
            [.rect(x: 3.5, y: 5, width: 17, height: 14, cornerRadius: 2.5), .circle(cx: 12, cy: 11, r: 2.6, filled: false),
             .path("M7 19c.8-2.6 2.8-4 5-4s4.2 1.4 5 4")]
        case .portrait:
            [.circle(cx: 12, cy: 8.5, r: 3.6, filled: false), .path("M5 20c1.2-3.8 4-5.6 7-5.6s5.8 1.8 7 5.6")]
        case .edit:
            [.path("M5 7h9M18 7h1M5 17h1M10 17h9"), .circle(cx: 16, cy: 7, r: 2, filled: false), .circle(cx: 8, cy: 17, r: 2, filled: false)]
        case .effects:
            [.path("M12 3l1.8 4.6L18.5 9l-4.7 1.6L12 15l-1.8-4.4L5.5 9l4.7-1.4z")]
        case .watermark:
            [.path("M4 17c2.5-4 4.5-9 7-9 1.6 0 1 4 2.6 4 1.3 0 1.7-2 3-2 1 0 1.6 1 3.4 2"), .path("M4 20h16")]
        case .border:
            [.rect(x: 3.5, y: 3.5, width: 17, height: 17, cornerRadius: 1.5), .rect(x: 7, y: 7, width: 10, height: 8, cornerRadius: 0.5)]
        case .star:
            [.path("M12 4.5l2.2 4.6 5 .7-3.6 3.5.9 5-4.5-2.4-4.5 2.4.9-5L4.8 9.8l5-.7z")]
        case .info:
            [.circle(cx: 12, cy: 12, r: 8.5, filled: false), .path("M12 11v5M12 8v.5")]
        case .warn:
            [.path("M12 4l9 16H3z"), .path("M12 10v4M12 17v.5")]
        case .brush:
            [.path("M14.5 4.5l5 5-8 8H6.5v-5z"), .path("M4 20h7")]
        case .erase:
            [.path("M8 20h12M5.5 14.5l7-7 5 5-5.5 5.5H9z")]
        case .plus:
            [.path("M12 5v14M5 12h14")]
        case .picker:
            [.path("M14.6 4.6A2.6 2.6 0 0 1 18.3 4.6L19.4 5.7A2.6 2.6 0 0 1 19.4 9.4L17.2 11.6L12.4 6.8Z"),
             .path("M11.2 7.6l5.2 5.2"), .path("M13.6 10.2L6.4 17.4L5 20L7.6 18.6L14.8 11.4")]
        case .rotl:
            [.path("M4 4v5h5"), .path("M4.5 9A8 8 0 1 1 6 16")]
        case .rotr:
            [.path("M20 4v5h-5"), .path("M19.5 9A8 8 0 1 0 18 16")]
        case .fliph:
            [.path("M12 3v18"), .path("M9 7L4 12l5 5z"), .path("M15 7l5 5-5 5z")]
        case .flipv:
            [.path("M3 12h18"), .path("M7 9l5-5 5 5z"), .path("M7 15l5 5 5-5z")]
        case .circle:
            [.circle(cx: 12, cy: 12, r: 7, filled: false)]
        case .hex:
            [.path("M12 4.5l6.5 3.75v7.5L12 19.5l-6.5-3.75v-7.5z")]
        case .heart:
            [.path("M12 19s-7-4.4-7-9.5A3.8 3.8 0 0 1 12 7a3.8 3.8 0 0 1 7 2.5C19 14.6 12 19 12 19z")]
        case .starShape:
            [.path("M12 5l2 4.6 5 .4-3.8 3.3 1.2 4.9L12 15.6 7.6 18.2l1.2-4.9L5 10l5-.4z")]
        case .share:
            [.path("M12 3v12M7.5 7.5 12 3l4.5 4.5"), .path("M5 12v6.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V12")]
        }
    }
}

/// Draws an `ApprovedIcon` at `size` points in the current foreground style.
struct ApprovedIconView: View {
    let icon: ApprovedIcon
    var size: CGFloat = 22
    /// CSS `fill: currentColor` on the whole icon (the starred star, `.star.on .icon`).
    var filled = false

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / ApprovedIcon.viewBox
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            for element in icon.elements {
                switch element {
                case .path(let data, let width):
                    let path = SVGPathParser.path(data).applying(transform)
                    if filled { context.fill(path, with: .foreground) }
                    context.stroke(path, with: .foreground, style: Self.style(width * scale))
                case .filledPath(let data):
                    context.fill(SVGPathParser.path(data).applying(transform), with: .foreground)
                case .rect(let x, let y, let width, let height, let radius):
                    let rect = Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius)
                    context.stroke(rect.applying(transform), with: .foreground, style: Self.style(ApprovedIcon.strokeWidth * scale))
                case .circle(let cx, let cy, let r, let filled):
                    let circle = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).applying(transform)
                    if filled {
                        context.fill(circle, with: .foreground)
                    } else {
                        context.stroke(circle, with: .foreground, style: Self.style(ApprovedIcon.strokeWidth * scale))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)  // The control carrying the icon has the label.
    }

    private static func style(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// Parses the subset of SVG path data the prototype's icons use: M, L, H, V, C, S, A and Z, absolute
/// and relative, with implicit command repetition and compact numbers ("4.5-4.5", ".01").
enum SVGPathParser {

    static func path(_ data: String) -> Path {
        var path = Path()
        var scanner = Scanner(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character = "M"
        // The second control point of the previous C/S segment, for S's reflected first one.
        var previousControl: CGPoint?

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let letter) = next {
                command = letter
                if letter == "Z" || letter == "z" {
                    path.closeSubpath()
                    current = subpathStart
                }
                continue
            }
            scanner.pushBack()
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            let upper = command.uppercased().first!
            let reflected = previousControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            if upper != "C" && upper != "S" { previousControl = nil }
            switch upper {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.move(to: current)
                subpathStart = current
                // Further pairs after a moveto are implicit linetos.
                command = relative ? "l" : "L"
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addLine(to: current)
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let end = CGPoint(x: origin.x + x, y: origin.y + y)
                let control2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
                path.addCurve(to: end, control1: CGPoint(x: origin.x + x1, y: origin.y + y1), control2: control2)
                current = end
                previousControl = control2
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let end = CGPoint(x: origin.x + x, y: origin.y + y)
                let control2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
                path.addCurve(to: end, control1: reflected, control2: control2)
                current = end
                previousControl = control2
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let largeArc = scanner.number(), let sweep = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = CGPoint(x: origin.x + x, y: origin.y + y)
                addArc(to: &path, from: current, to: end, radii: CGSize(width: rx, height: ry),
                       rotationDegrees: rotation, largeArc: largeArc != 0, sweep: sweep != 0)
                current = end
            default:
                return path
            }
        }
        return path
    }

    /// SVG endpoint arc → centre parameterisation (SVG 1.1 implementation notes, F.6.5), drawn
    /// as a transformed unit-circle arc.
    private static func addArc(
        to path: inout Path, from start: CGPoint, to end: CGPoint, radii: CGSize,
        rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0, start != end else { path.addLine(to: end); return }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let centre = CGPoint(x: cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2,
                             y: sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(1, max(-1, dot)))
        }
        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let transform = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: phi).scaledBy(x: rx, y: ry)
        var unitArc = Path()
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 8))))
        for index in 0...segments {
            let theta = startAngle + delta * CGFloat(index) / CGFloat(segments)
            let point = CGPoint(x: cos(theta), y: sin(theta))
            if index == 0 { unitArc.move(to: point) } else { unitArc.addLine(to: point) }
        }
        // Flattened at π/8 steps and replayed as lines after the current point: at icon sizes
        // (≤ 44 pt, radii ≤ 2.5 units) the chords are sub-pixel.
        unitArc.applying(transform).forEach { element in
            if case .line(let to) = element { path.addLine(to: to) }
        }
        path.addLine(to: end)
    }

    /// Tokeniser over the path string.
    private struct Scanner {
        enum Token { case command(Character), number(CGFloat) }

        private let characters: [Character]
        private var index = 0
        private var lastTokenStart = 0

        init(_ string: String) { characters = Array(string) }

        mutating func pushBack() { index = lastTokenStart }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < characters.count else { return nil }
            lastTokenStart = index
            let character = characters[index]
            if character.isLetter && character != "e" && character != "E" {
                index += 1
                return .command(character)
            }
            return number().map(Token.number)
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
            var sawDot = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber { index += 1; continue }
                if character == ".", !sawDot { sawDot = true; index += 1; continue }
                break
            }
            guard index > start, let value = Double(String(characters[start..<index])) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == "," { index += 1 }
        }
    }
}
