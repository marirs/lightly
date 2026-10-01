import SwiftUI

/// Bottom actions before development (spec §4.3).
///
/// Crop and Develop only. Compare is *absent from this bar entirely* — §0.11
/// requires it to be unavailable until a developed version exists, and omitting
/// the control is clearer than rendering a dead one.
struct PreDevelopActionBar: View {
    let onCrop: () -> Void
    let onDevelop: () -> Void

    /// Whether to render a visibly disabled Compare instead of omitting it.
    ///
    /// The spec permits "hidden or disabled". Hiding is the default because a
    /// disabled control still invites a tap; the flag exists so the choice is
    /// explicit and reviewable rather than accidental.
    var showsDisabledCompare: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes the side-by-side arrangement cannot
                // hold "Develop" on one line. Stacking gives the primary action
                // the full width rather than hyphenating it, which is the point
                // of supporting Dynamic Type at all.
                VStack(spacing: LightlySpacing.m) {
                    developButton
                        .frame(maxWidth: .infinity)

                    HStack {
                        secondaryAction(symbol: "crop", labelKey: "action.crop", action: onCrop)
                        Spacer()
                        disabledCompareIfNeeded
                    }
                }
            } else {
                HStack {
                    secondaryAction(symbol: "crop", labelKey: "action.crop", action: onCrop)

                    Spacer()

                    developButton

                    Spacer()

                    if showsDisabledCompare {
                        disabledCompareIfNeeded
                    } else {
                        // Balances Crop so Develop stays optically centred.
                        secondaryAction(symbol: "crop", labelKey: "action.crop", action: {})
                            .hidden()
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.horizontal, LightlySpacing.l)
    }

    @ViewBuilder
    private var disabledCompareIfNeeded: some View {
        if showsDisabledCompare {
            secondaryAction(
                symbol: "rectangle.righthalf.inset.filled",
                labelKey: "action.compare",
                action: {}
            )
            .disabled(true)
            .opacity(0.35)
            .accessibilityHint(Text("action.compare.unavailable", bundle: .main))
        }
    }

    private var developButton: some View {
        Button(action: onDevelop) {
            HStack(spacing: LightlySpacing.xs) {
                Text("action.develop", bundle: .main)
                    .font(LightlyTypography.actionPrimary)
                    // The label must never hyphenate; the layout above grants
                    // it the room it needs instead.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(LightlyColor.textPrimary(colorScheme))
            .padding(.horizontal, LightlySpacing.l)
            .padding(.vertical, LightlySpacing.s + 2)
            // Same rule as EditorView.controlsReservePhotoSpace: at
            // accessibility sizes this bar sits on the plain background.
            .controlChrome(
                Capsule(), onPlainBackground: dynamicTypeSize.isAccessibilitySize, colorScheme: colorScheme
            )
            .layoutAnchor("editor.develop")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("action.develop")
    }

    private func secondaryAction(
        symbol: String,
        labelKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: LightlySpacing.xxs) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                Text(labelKey, bundle: .main)
                    .font(LightlyTypography.caption)
            }
            .foregroundStyle(LightlyColor.textPrimary(colorScheme))
            .frame(minWidth: LightlySize.minimumTapTarget, minHeight: LightlySize.minimumTapTarget)
        }
        .buttonStyle(.plain)
    }
}

/// The single contextual bottom action bar shown after development (§4.5).
///
/// Spec §0.11 locks this as the *only* navigation model for tools — the
/// separate generic Tools grid from the early mockups is deliberately not
/// implemented.
struct ContextualActionBar: View {
    let tools: [ContextualTool]
    let onSelect: (ContextualTool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Five equal columns cannot hold legible labels at accessibility
                // sizes — they collide and truncate. Scrolling keeps every tool
                // fully readable and tappable instead of shrinking the text back
                // down, which would defeat the user's setting.
                // Wraps onto multiple rows rather than scrolling: every tool
                // stays visible. A horizontally scrolling bar would hide tools
                // off-screen with no affordance, which is a worse outcome for
                // the users who need large text most.
                VStack(spacing: LightlySpacing.m) {
                    ForEach(Array(toolRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(row) { tool in
                                toolButton(tool).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal, LightlySpacing.s)
            } else {
                HStack(spacing: 0) {
                    ForEach(tools) { tool in
                        toolButton(tool).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, LightlySpacing.s)
            }
        }
        .padding(.vertical, LightlySpacing.s)
        .background(
            RoundedRectangle(cornerRadius: LightlyRadius.sheet, style: .continuous)
                .fill(.regularMaterial)
        )
        .padding(.horizontal, LightlySpacing.m)
    }

    /// Tools split into rows for the accessibility layout.
    ///
    /// Three per row keeps each label legible at the largest text sizes while
    /// still reading as a single bar rather than a grid of icons.
    private var toolRows: [[ContextualTool]] {
        stride(from: 0, to: tools.count, by: 3).map { start in
            Array(tools[start..<min(start + 3, tools.count)])
        }
    }

    private func toolButton(_ tool: ContextualTool) -> some View {
        Button {
            onSelect(tool)
        } label: {
            VStack(spacing: LightlySpacing.xxs) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 19, weight: .light))
                Text(LocalizedStringKey(tool.localizationKey), bundle: .main)
                    .font(LightlyTypography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(LightlyColor.textPrimary(colorScheme))
            .frame(minHeight: LightlySize.minimumTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool.\(tool.rawValue)")
    }
}
