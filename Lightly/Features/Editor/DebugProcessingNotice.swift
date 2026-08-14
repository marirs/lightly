import SwiftUI

/// A persistent, non-dismissible notice that the active Develop engine is not
/// the production one.
///
/// Required by spec §24.8: placeholder image processing must never be presented
/// as finished functionality. The notice is deliberately plain and slightly
/// unattractive — it is a scaffold, and it should read as one, so that nobody
/// screenshots this build and mistakes it for the product.
///
/// It states the distinction precisely, because "mock" alone would be
/// misleading in both directions: the rendering really does change pixels, and
/// the analysis really is absent.
struct DebugProcessingNotice: View {

    var body: some View {
        HStack(spacing: LightlySpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))

            Text("debug.processing.notice", bundle: .main)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, LightlySpacing.s)
        .padding(.vertical, LightlySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                .fill(Color(red: 1.0, green: 0.84, blue: 0.25))
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    DebugProcessingNotice()
}
