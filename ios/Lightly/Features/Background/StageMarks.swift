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

/// `.faceRing`: an ellipse on each face; the chosen one solid, others dashed at 75 %. With more
/// than one face, a "Face N" tag below each. People without a usable face get dim rings.
struct FaceRingsMark: View {
    let faces: [EditRecipe.Rect]
    let selected: Int
    let people: [EditRecipe.Rect]
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ForEach(faces.indices, id: \.self) { index in
                let rect = frame(faces[index], in: size)
                Button { onSelect(index) } label: {
                    ring(dim: index != selected)
                }
                .buttonStyle(.plain)
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .bottom) {
                    if faces.count > 1 {
                        Text("Face \(index + 1)")
                            .font(.system(size: 12)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.55)))
                            .fixedSize()
                            .offset(y: 6)
                            .alignmentGuide(.bottom) { $0[.top] }
                    }
                }
                .position(x: rect.midX, y: rect.midY)
                .accessibilityLabel(Text("Face \(index + 1)"))
                .accessibilityAddTraits(index == selected ? .isSelected : [])
                .accessibilityIdentifier("portrait.ring.\(index + 1)")
            }
            ForEach(people.indices, id: \.self) { index in
                let rect = frame(people[index], in: size)
                ring(dim: true).frame(width: rect.width * 0.35, height: rect.width * 0.35)
                    .position(x: rect.midX, y: rect.minY + rect.width * 0.25)
                    .allowsHitTesting(false)
            }
        }
    }

    private func frame(_ r: EditRecipe.Rect, in size: CGSize) -> CGRect {
        CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private func ring(dim: Bool) -> some View {
        ZStack {
            // `box-shadow: 0 0 0 1px`: 1 pt just outside the ring's border box.
            Ellipse().strokeBorder(Color.black.opacity(0.2), lineWidth: 1).padding(-1)
            // 1 pt as rendered: the approved references floor CSS border widths (Chromium computes 1.5px as 1px, 2.5px as 2px).
            Ellipse().strokeBorder(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 1, dash: dim ? [5, 4] : []))
        }
        .opacity(dim ? 0.75 : 1)
        .contentShape(Ellipse())
    }
}
