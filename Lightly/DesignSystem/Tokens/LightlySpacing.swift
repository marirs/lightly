import CoreGraphics

/// Spacing, radius, and sizing constants.
///
/// Lightly's layout rhythm is a 4pt base scale. Named tokens are used instead of
/// literals so that the calm, generous spacing of the mockups survives future
/// edits by anyone who did not draw them.
enum LightlySpacing {
    /// 4pt — hairline gaps, icon-to-label in dense rows.
    static let xxs: CGFloat = 4
    /// 8pt — tight internal padding.
    static let xs: CGFloat = 8
    /// 12pt — related element grouping.
    static let s: CGFloat = 12
    /// 16pt — default internal padding for rows and cards.
    static let m: CGFloat = 16
    /// 24pt — screen edge insets, gap between grouped controls.
    static let l: CGFloat = 24
    /// 32pt — separation between distinct content blocks.
    static let xl: CGFloat = 32
    /// 48pt — major vertical breathing room on the launch screen.
    static let xxl: CGFloat = 48
}

/// Corner radii.
enum LightlyRadius {
    /// Rows inside the source sheet.
    static let row: CGFloat = 14
    /// The source-selection sheet itself.
    static let sheet: CGFloat = 28
    /// Fully rounded controls (the Develop button).
    static let pill: CGFloat = 999
}

/// Fixed control dimensions that must stay consistent across screens.
enum LightlySize {
    /// Minimum tap target, per Apple HIG.
    static let minimumTapTarget: CGFloat = 44
    /// The eight-ray brand mark on the launch screen.
    static let brandMarkLaunch: CGFloat = 56
    /// Leading icon inside a source-selection row.
    static let rowIcon: CGFloat = 24
}
