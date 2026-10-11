import SwiftUI
import UIKit

/// The one colour control (Lightly 2 `colourStrip`), identical wherever a colour is chosen (Background, Border,
/// Watermark): a header row ("Title · Name", and "More colours ›"), then the 24-colour strip, 40 pt tall, a 22 pt
/// accent ring on the chosen colour. Dragging along the strip previews; lifting commits one undo step. "More colours"
/// opens the colour sheet (any colour).
struct ColourControl: View {
    var title = "Colour"
    /// The current colour, `#RRGGBB`.
    let selected: String
    let photo: CGImage
    var identifier = "colour"
    var preview: ((String) -> Void)? = nil
    var previewImage: (() -> CGImage)? = nil
    var cancel: (() -> Void)? = nil
    let choose: (String) -> Void

    /// `COLOURS` in the mockup, in strip order.
    static let colours: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Warm white", "#F4F1EC"), ("Light stone", "#D9D4CC"), ("Cool grey", "#C4C9CE"),
        ("Blue grey", "#9AA3A8"), ("Slate", "#3C4A55"), ("Charcoal", "#1F2328"), ("Black", "#0B0B0C"),
        ("Cream", "#F3E3C3"), ("Mustard", "#D9A82E"), ("Tan", "#C9A27E"), ("Terracotta", "#C2684A"),
        ("Rust", "#8A5A44"), ("Blush", "#E8B4B0"), ("Rose", "#B5536B"), ("Plum", "#5B3A6B"),
        ("Lilac", "#B8A9D9"), ("Sky", "#A9D3EE"), ("Ocean", "#2F6F9F"), ("Navy", "#1E2F4D"),
        ("Mint", "#BFE3D0"), ("Sage", "#A8B89A"), ("Olive", "#6E6B3A"), ("Forest green", "#4E6B5A"),
    ]

    @State private var sheetShown = false
    @State private var dragIndex: Int?
    @Environment(\.colorScheme) private var scheme

    private var selectedIndex: Int? {
        Self.colours.firstIndex { $0.hex.caseInsensitiveCompare(selected) == .orderedSame }
    }

    var body: some View {
        let c = L2(scheme: scheme)
        let shownIndex = dragIndex ?? selectedIndex
        // A colour from the sheet that is not on the strip is named by its hex value and has no ring.
        let name = shownIndex.map { Self.colours[$0].name } ?? selected.uppercased()
        VStack(spacing: 8) {
            HStack {
                (Text(LocalizedStringKey(title)) + Text(" · ") + Text(LocalizedStringKey(name)).foregroundColor(c(ApprovedColor.ink)))
                    .l2Text(13, weight: .semibold)
                    .foregroundStyle(c(ApprovedColor.inkSecondary))
                Spacer(minLength: 8)
                Button { sheetShown = true } label: { L2Label(title: Text("More colours"), icon: .chevron, iconSize: 15, iconTrailing: true) }
                    .buttonStyle(L2LinkButtonStyle())
                    .accessibilityIdentifier(identifier + ".more")
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let segment = width / CGFloat(Self.colours.count)
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Self.colours.indices, id: \.self) { index in
                            Rectangle().fill(Color(hex: UInt32(Self.colours[index].hex.dropFirst(), radix: 16) ?? 0))
                        }
                    }
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
                    if let shownIndex {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(c(ApprovedColor.selection), lineWidth: 3)
                            .frame(width: 22, height: 50)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(c(ApprovedColor.sheet), lineWidth: 2).padding(-1))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                            .offset(x: segment * (CGFloat(shownIndex) + 0.5) - 11)
                    }
                }
                .frame(height: 40)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = min(max(Int(value.location.x / max(segment, 1)), 0), Self.colours.count - 1)
                        if dragIndex != index { dragIndex = index; preview?(Self.colours[index].hex) }
                    }
                    .onEnded { value in
                        let index = min(max(Int(value.location.x / max(segment, 1)), 0), Self.colours.count - 1)
                        dragIndex = nil
                        choose(Self.colours[index].hex)
                    })
            }
            .frame(height: 40)
            .padding(.horizontal, 2)
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey(title)))
            .accessibilityValue(Text(LocalizedStringKey(name)))
            .accessibilityAdjustableAction { direction in
                let current = selectedIndex ?? 0
                let next = min(max(current + (direction == .increment ? 1 : -1), 0), Self.colours.count - 1)
                choose(Self.colours[next].hex)
            }
            .accessibilityIdentifier(identifier + ".strip")
        }
        .fullScreenCover(isPresented: $sheetShown, onDismiss: { cancel?() }) {
            ColourSheet(title: title, selected: selected, photo: photo, preview: preview, previewImage: previewImage,
                        choose: choose, dismiss: { sheetShown = false })
                .presentationBackground(.clear)
        }
        .transaction { if sheetShown { $0.disablesAnimations = false } }
    }
}

/// `colourSheet`: the sheet behind "More colours", the same from every colour control. sheetHead (Cancel · title ·
/// Done), the live preview (170 pt phone / 200 pt tablet, 18 pt corners, stage fill), "From your photo", "Paper & ink",
/// "Earth" (five 40 pt swatches each, 12 pt corners, 9 pt gaps, lime check on the chosen one), the Custom row (opens the
/// system colour panel) and "Recent".
struct ColourSheet: View {
    let title: String
    let photo: CGImage
    let choose: (String) -> Void
    let preview: ((String) -> Void)?
    let previewImage: (() -> CGImage)?
    let dismiss: () -> Void
    @AppStorage("lightly.recentColours") private var recent = "#FFFFFF,#111111,#F4F1EC"
    @State private var hex: String
    @State private var showsPicker = false
    @State private var palette: [String] = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(title: String, selected: String, photo: CGImage, preview: ((String) -> Void)?, previewImage: (() -> CGImage)?,
         choose: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.title = title; self.photo = photo; self.preview = preview; self.previewImage = previewImage
        self.choose = choose; self.dismiss = dismiss
        _hex = State(initialValue: selected.uppercased())
    }

    private var valid: Bool { hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }
    private var isTablet: Bool { sizeClass == .regular }

    var body: some View {
        let c = L2(scheme: scheme)
        ApprovedSheetOverlay(isTablet: isTablet, heightFraction: isTablet ? 0.92 : 0.9, onDismiss: dismiss) {
            L2SheetHeader(title: Text(LocalizedStringKey(title)),
                          leading: { L2TextButton(title: "Cancel", identifier: "colour.cancel", action: dismiss) },
                          trailing: { L2TextButton(title: "Done", isBold: true, isEnabled: valid, identifier: "colour.done", action: done) })
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c(ApprovedColor.canvas))
                        Image(decorative: previewImage?() ?? photo, scale: 1)
                            .resizable().scaledToFit().padding(8)
                            .accessibilityLabel(Text("Preview"))
                    }
                    .frame(height: isTablet ? 200 : 170)
                    section("From your photo", palette)
                    section("Paper & ink", ["#FFFFFF", "#ECE8DF", "#D4C9B5", "#9C9284", "#242423"])
                    section("Earth", ["#DFC7AE", "#B98767", "#914E3E", "#66775D", "#334538"])
                    customRow
                    section("Recent", recent.split(separator: ",").map(String.init), fixedWidth: true)
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .task { palette = PhotoColours.palette(photo) }
        .onChange(of: hex) { _, value in if valid { preview?(value.uppercased()) } }
    }

    /// Custom (owner, 2026-10-11): tapping the row opens the system colour panel. No hex field (its keyboard covered
    /// the sheet) and no eyedropper button.
    private var customRow: some View {
        let c = L2(scheme: scheme)
        return Button { showsPicker = true } label: {
            HStack(spacing: 10) {
                Circle().fill(AngularGradient(colors: [0xFF4444, 0xFFDD44, 0x44FF88, 0x44DDFF, 0x8844FF, 0xFF44CC, 0xFF4444].map { Color(hex: $0) },
                                              center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
                    .frame(width: 40, height: 40)
                Text("Custom").l2Text(14, weight: .semibold).foregroundStyle(c(ApprovedColor.ink))
                Spacer(minLength: 0)
                ApprovedIconView(icon: .chevron, size: 16).foregroundStyle(c(ApprovedColor.inkTertiary))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("colour.custom")
        .sheet(isPresented: $showsPicker) {
            // Tall enough for the whole panel (grid, swatch and saved colours); .medium cut the swatch row off.
            SystemColourPanel(hex: $hex).presentationDetents([.height(530), .large])
        }
    }

    private func section(_ name: String, _ colours: [String], fixedWidth: Bool = false) -> some View {
        let c = L2(scheme: scheme)
        return VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(name)).l2Text(12, weight: .bold).foregroundStyle(c(ApprovedColor.inkSecondary))
                .padding(.top, 4)
            HStack(spacing: 9) {
                ForEach(colours, id: \.self) { colour in
                    let isOn = hex.caseInsensitiveCompare(colour) == .orderedSame
                    Button { hex = colour.uppercased() } label: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: UInt32(colour.dropFirst(), radix: 16) ?? 0))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
                            .overlay(alignment: .topTrailing) {
                                if isOn {
                                    ApprovedIconView(icon: .check, size: 10).foregroundStyle(c(ApprovedColor.onAccent))
                                        .frame(width: 16, height: 16).background(Circle().fill(c(ApprovedColor.accent))).padding(4)
                                }
                            }
                            .frame(width: fixedWidth ? 40 : nil, height: 40)
                            .frame(maxWidth: fixedWidth ? nil : .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Colour \(colour)"))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    private func done() {
        let colour = hex.uppercased()
        recent = ([colour] + recent.split(separator: ",").map(String.init).filter { $0 != colour }).prefix(8).joined(separator: ",")
        choose(colour)
        dismiss()
    }
}

enum PhotoColours {
    static func small(_ image: CGImage, edge: Int = 64) -> CGImage? {
        let ratio = min(1, Double(edge) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * ratio)), h = max(1, Int(Double(image.height) * ratio))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high; ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.makeImage()
    }
    static func sample(_ image: CGImage, x: Double, y: Double) -> String {
        guard let small = small(image, edge: 512), let bytes = try? MetalLUTRenderer.rgba8Bytes(of: small) else { return "#000000" }
        let px = min(small.width-1, max(0, Int(x*Double(small.width)))), py = min(small.height-1, max(0, Int(y*Double(small.height))))
        let i = (py*small.width+px)*4
        return String(format: "#%02X%02X%02X", Int(bytes[i]), Int(bytes[i+1]), Int(bytes[i+2]))
    }
    static func palette(_ image: CGImage) -> [String] {
        guard let image = small(image), let bytes = try? MetalLUTRenderer.rgba8Bytes(of: image) else { return [] }
        var bins: [Int: (Int, Int, Int, Int)] = [:]
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2]), key = (r/32)*64+(g/32)*8+b/32
            let v = bins[key] ?? (0,0,0,0); bins[key] = (v.0+1,v.1+r,v.2+g,v.3+b)
        }
        let ranked = bins.sorted { $0.value.0 == $1.value.0 ? $0.key < $1.key : $0.value.0 > $1.value.0 }
        var colours: [(Int, Int, Int)] = []
        for (_, v) in ranked {
            let c = (v.1/v.0, v.2/v.0, v.3/v.0)
            if colours.allSatisfy({ pow(Double($0.0-c.0),2) + pow(Double($0.1-c.1),2) + pow(Double($0.2-c.2),2) >= 3025 }) { colours.append(c) }
            if colours.count == 5 { break }
        }
        return colours.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) }
    }
}

/// The system colour panel (UIColorPickerViewController), writing the chosen colour back as #RRGGBB.
private struct SystemColourPanel: UIViewControllerRepresentable {
    @Binding var hex: String

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = UIColor(Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF))
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let hex: Binding<String>
        init(hex: Binding<String>) { self.hex = hex }

        func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let channel = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
            hex.wrappedValue = String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
        }
    }
}
