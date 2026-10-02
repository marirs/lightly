import SwiftUI

/// Motion constants.
///
/// Spec §4.1 requires launch motion that is "smooth and restrained", and §0.11
/// requires the swipe affordance to nudge *gently* after an idle period. Timing
/// lives here so that "restrained" is a single reviewable decision rather than a
/// value re-guessed at each call site.
enum LightlyMotion {

    /// Standard transition for revealing or dismissing a surface.
    static let surface = Animation.spring(response: 0.48, dampingFraction: 0.86)

    /// Slower, softer curve for ambient/decorative movement (mountain parallax).
    static let ambient = Animation.easeInOut(duration: 0.9)

    /// The looping nudge applied to the swipe affordance once idle.
    static let affordanceNudge = Animation.easeInOut(duration: 1.4)

    /// How long the user may sit on the launch screen before the swipe
    /// affordance begins hinting. Long enough not to feel impatient, short
    /// enough that a confused user is not stranded (spec §0.11).
    static let idleBeforeAffordanceHint: Duration = .seconds(2.5)

    /// Vertical travel of the affordance nudge, in points. Deliberately small —
    /// the hint should register peripherally, not demand attention.
    static let affordanceNudgeTravel: CGFloat = 6
}
