import SwiftUI

/// The approved design's line icons, drawn from the prototype's own 24-unit SVG geometry
/// (`ICON` in `docs/ui/app/app.js`): 1.6-unit round strokes that scale with the icon.
///
/// Drawn natively from the same path data rather than substituted with SF Symbols, whose shapes
/// and weights differ visibly at these sizes.
/// The approved Lightly 2 line icons, copied from the mockup's own 24-unit SVG geometry (`IC` and `ic()` in
/// docs/ui/directions/lightly-2-concept/index.html): 1.9-unit round strokes that scale with the icon.
///
/// Drawn natively from the same path data rather than substituted with SF Symbols, whose shapes
/// and weights differ visibly at these sizes.
enum ApprovedIcon: String, CaseIterable, Sendable {
    case close, back, undo, redo, chevron, check, star, develop, background, portrait, edit, effects, watermark, border, photo, camera, brush, erase, info, warn, share, plus, eye, rotl, rotr, fliph, flipv, grip, trash, search, flash, circle, hex, heart, starShape, reset, wand, pencil, dropper, flip, ellipsis, mail, picker, more, compare

    /// One drawing primitive in the 24×24 view box.
    enum Element: Sendable {
        case path(String, strokeWidth: CGFloat = ApprovedIcon.strokeWidth)
        /// `fill="currentColor" stroke="none"` (the filled half of Compare).
        case filledPath(String)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat, filled: Bool, strokeWidth: CGFloat = ApprovedIcon.strokeWidth)
    }

    static let viewBox: CGFloat = 24
    /// `stroke-width="1.9"` in `ic()`.
    static let strokeWidth: CGFloat = 1.9

    var elements: [Element] {
        switch self {
        // `ic('more')`: three filled dots, r 1.8.
        case .more:
            [.circle(cx: 12, cy: 5, r: 1.8, filled: true), .circle(cx: 12, cy: 12, r: 1.8, filled: true), .circle(cx: 12, cy: 19, r: 1.8, filled: true)]
        // `ic('compare')`: a 2-unit ring, r 8, its right half filled.
        case .compare:
            [.circle(cx: 12, cy: 12, r: 8, filled: false, strokeWidth: 2), .filledPath("M12 4a8 8 0 010 16z")]
        // `ic('ellipsis')` draws its dots with a 3.2-unit stroke.
        case .ellipsis:
            [.path("M5 12h.01M12 12h.01M19 12h.01", strokeWidth: 3.2)]
        case .close:
            [.path("M6 6l12 12M18 6L6 18")]
        case .back:
            [.path("M15 5l-7 7 7 7")]
        case .undo:
            [.path("M9 14L4 9l5-5M4 9h10a6 6 0 010 12h-3")]
        case .redo:
            [.path("M15 14l5-5-5-5M20 9H10a6 6 0 000 12h3")]
        case .chevron:
            [.path("M9 6l6 6-6 6")]
        case .check:
            [.path("M5 12l5 5 9-10")]
        case .star:
            [.path("M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z")]
        case .develop:
            [.path("M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M18 6l-2.5 2.5M8.5 15.5L6 18")]
        case .background:
            [.path("M5 4h14a2 2 0 012 2v12a2 2 0 01-2 2H5a2 2 0 01-2-2V6a2 2 0 012-2zM12 7.5a2.5 2.5 0 100 5 2.5 2.5 0 000-5zM7.5 20c.8-3 2.4-4.5 4.5-4.5s3.7 1.5 4.5 4.5")]
        case .portrait:
            [.path("M12 4.5a3.5 3.5 0 100 7 3.5 3.5 0 000-7zM5 20c1-4 3.6-6 7-6s6 2 7 6")]
        case .edit:
            [.path("M4 7h10M18 7h2M4 17h4M12 17h8M16 5v4M10 15v4")]
        case .effects:
            [.path("M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z")]
        case .watermark:
            [.path("M3 17c3 0 4-9 6-9s1 8 3 8 2-5 4-5 2 3 5 3")]
        case .border:
            [.path("M4 4h16v16H4zM8 8h8v8H8z")]
        case .photo:
            [.path("M5 4h14a2 2 0 012 2v12a2 2 0 01-2 2H5a2 2 0 01-2-2V6a2 2 0 012-2zM9 8.2a1.8 1.8 0 100 3.6 1.8 1.8 0 000-3.6zM21 16l-5-5-9 9")]
        case .camera:
            [.path("M4 8h3l2-3h6l2 3h3v11H4zM12 9.5a3.5 3.5 0 100 7 3.5 3.5 0 000-7z")]
        case .brush:
            [.path("M14 4l6 6-8 8H6v-6z")]
        case .erase:
            [.path("M7 20h10M4 14l8-8 6 6-6 6H8z")]
        case .info:
            [.path("M12 3a9 9 0 100 18 9 9 0 000-18zM12 11v5M12 8h.01")]
        case .warn:
            [.path("M12 3l10 18H2zM12 10v5M12 18h.01")]
        case .share:
            [.path("M12 15V4M7 9l5-5 5 5M5 14v6h14v-6")]
        case .plus:
            [.path("M12 5v14M5 12h14")]
        case .eye:
            [.path("M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 9a3 3 0 100 6 3 3 0 000-6z")]
        case .rotl:
            [.path("M4 8v5h5M5 13a8 8 0 112 5")]
        case .rotr:
            [.path("M20 8v5h-5M19 13a8 8 0 11-2 5")]
        case .fliph:
            [.path("M12 3v18M8 7L4 12l4 5zM16 7l4 5-4 5z")]
        case .flipv:
            [.path("M3 12h18M7 8l5-4 5 4zM7 16l5 4 5-4z")]
        case .grip:
            [.path("M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01")]
        case .trash:
            [.path("M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3")]
        case .search:
            [.path("M11 4a7 7 0 100 14 7 7 0 000-14zM20 20l-4-4")]
        case .flash:
            [.path("M13 2L5 14h6l-1 8 8-12h-6z")]
        case .circle:
            [.path("M12 4a8 8 0 100 16 8 8 0 000-16z")]
        case .hex:
            [.path("M12 3l8 4.5v9L12 21l-8-4.5v-9z")]
        case .heart:
            [.path("M12 20s-8-5-8-11a4.5 4.5 0 018-2.8A4.5 4.5 0 0120 9c0 6-8 11-8 11z")]
        case .starShape:
            [.path("M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z")]
        case .reset:
            [.path("M4 4v6h6M5.5 15a8 8 0 102-8.5L4 10")]
        case .wand:
            [.path("M4 20L15 9M14 4v3M18.5 5.5l-2 2M20 10h-3M9 4.5l1 1.5M17 14l1 1.5")]
        case .pencil:
            [.path("M4 20h4L19 9l-4-4L4 16zM13 7l4 4")]
        case .dropper:
            [.path("M14 5l5 5M12 7l5 5-8 8H4v-5zM16 3l5 5-2 2-5-5z")]
        case .flip:
            [.path("M4 8h12l-3-3M20 16H8l3 3")]
        case .mail:
            [.path("M3 6h18v12H3zM3 7l9 6 9-6")]
        case .picker:
            [.path("M12 3a9 9 0 100 18 9 9 0 000-18zM12 8v8M8 12h8")]
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
                case .circle(let cx, let cy, let r, let filled, let width):
                    let circle = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).applying(transform)
                    if filled {
                        context.fill(circle, with: .foreground)
                    } else {
                        context.stroke(circle, with: .foreground, style: Self.style(width * scale))
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

/// Parses the subset of SVG path data the mockup's icons use: M, L, H, V, C, S, A and Z, absolute
/// and relative, with implicit command repetition, compact numbers ("4.5-4.5", ".01") and compact arc flags ("0 012 2").
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
                // The two arc flags are single digits that may run into the next number ("a6 6 0 010 12" is
                // flags 0 and 1, then x 0): read them one character each, as SVG specifies.
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = CGPoint(x: origin.x + x, y: origin.y + y)
                addArc(to: &path, from: current, to: end, radii: CGSize(width: rx, height: ry),
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
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

        /// An arc flag: exactly one "0" or "1".
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < characters.count, characters[index] == "0" || characters[index] == "1" else { return nil }
            defer { index += 1 }
            return characters[index] == "1"
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
