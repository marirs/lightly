import SwiftUI

/// Marks drawn over the photo itself (prototype `marksFor`), sized to the fitted image.

/// `.target`: the focus point, a 52 pt white ring with a 6 pt dot.
struct FocusTargetMark: View {
    let point: CGPoint
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // `box-shadow: 0 0 0 1px`: a 1 pt ring just outside the 52 pt border box.
                Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1).frame(width: 54, height: 54)
                // 1 pt as rendered: the approved references floor CSS border widths (Chromium computes 1.5px as 1px, 2.5px as 2px).
                Circle().strokeBorder(.white, lineWidth: 1).frame(width: 52, height: 52)
                Circle().fill(.white).frame(width: 6, height: 6)
            }
            .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `.maskTint`: the subject, tinted blue at 32 %, while refining edges.
struct MatteTintMark: View {
    let matte: CGImage?
    var body: some View {
        if let matte {
            Color(red: 47 / 255, green: 107 / 255, blue: 235 / 255).opacity(0.32)
                .mask(Image(decorative: matte, scale: 1).resizable())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Portrait's face targets on the photo. Owner amendment (2026-10-14): nothing is drawn on the face — no ring, no
/// "Face N" tag, no dim marks for unusable people ("you can do it invisibly"); it covered the face while adding
/// sunglasses. Each usable face stays an invisible, tappable ellipse that chooses it, with its VoiceOver label.
struct FaceRingsMark: View {
    let faces: [EditRecipe.Rect]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ForEach(faces.indices, id: \.self) { index in
                let rect = frame(faces[index], in: size)
                Button { onSelect(index) } label: {
                    Color.clear.contentShape(Ellipse())
                }
                .buttonStyle(.plain)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .accessibilityLabel(Text("Face \(index + 1)"))
                .accessibilityAddTraits(index == selected ? .isSelected : [])
                .accessibilityIdentifier("portrait.ring.\(index + 1)")
            }
        }
    }

    private func frame(_ r: EditRecipe.Rect, in size: CGSize) -> CGRect {
        CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}
