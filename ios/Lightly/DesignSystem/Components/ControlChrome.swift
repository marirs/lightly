import SwiftUI

extension View {
    /// The fill behind an editor control.
    ///
    /// Over the photograph (standard sizes) a frosted material reads as a
    /// button because the image behind it shows through. On the plain
    /// background (accessibility sizes, where controls are moved off the
    /// photo) the same material is almost the background colour, so the
    /// control lost its shape and "Develop" read as a label. There it gets a
    /// solid elevated fill and a `controlBoundary` stroke (≥ 3:1, WCAG
    /// 1.4.11). Labels on `surfaceElevated` keep ≥ 4.5:1.
    @ViewBuilder
    func controlChrome<S: InsettableShape>(
        _ shape: S, onPlainBackground: Bool, colorScheme: ColorScheme
    ) -> some View {
        if onPlainBackground {
            background(LightlyColor.surfaceElevated(colorScheme), in: shape)
                .overlay(shape.strokeBorder(LightlyColor.controlBoundary(colorScheme), lineWidth: 1.5))
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
