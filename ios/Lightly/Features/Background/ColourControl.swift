import SwiftUI
import UIKit

/// Shared picker for colours in Border, Watermark and Background. A sheet is one undo step.
struct ColourControl: View {
    var title = "Colour"
    let selected: String
    let photo: CGImage
    var identifier = "colour"
    var preview: ((String) -> Void)? = nil
    var previewImage: (() -> CGImage)? = nil
    var cancel: (() -> Void)? = nil
    let choose: (String) -> Void
    @State private var shown = false
    var body: some View {
        HStack {
            Text(title).approvedText(15)
            Spacer()
            Button { shown = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: UInt32(selected.dropFirst(), radix: 16) ?? 0))
                        .overlay(Circle().stroke(.gray.opacity(0.4), lineWidth: 1)).frame(width: 24, height: 24)
                    Text("Choose colour").approvedText(14)
                    Image(systemName: "chevron.right").font(.system(size: 12))
                }.padding(.horizontal, 12).frame(minHeight: 44)
                    .background(.quaternary, in: Capsule())
            }.buttonStyle(.plain).accessibilityValue(selected).accessibilityIdentifier(identifier + ".picker")
        }.padding(.horizontal, 18).padding(.vertical, 6)
            .sheet(isPresented: $shown, onDismiss: { cancel?() }) { ColourSheet(title: title, selected: selected, photo: photo, preview: preview, previewImage: previewImage, choose: choose) }
    }
}

struct ColourSheet: View {
    let title: String
    let photo: CGImage
    let choose: (String) -> Void
    let preview: ((String) -> Void)?
    let previewImage: (() -> CGImage)?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lightly.recentColours") private var recent = "#FFFFFF,#111111,#F4F1EC"
    @State private var hex: String
    @State private var sampling = false
    @State private var palette: [String] = []
    init(title: String, selected: String, photo: CGImage, preview: ((String) -> Void)?, previewImage: (() -> CGImage)?, choose: @escaping (String) -> Void) {
        self.title = title; self.photo = photo; self.preview = preview; self.previewImage = previewImage; self.choose = choose; _hex = State(initialValue: selected)
    }
    private var valid: Bool { hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !sampling {
                        Image(decorative: previewImage?() ?? photo, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).frame(height: 180)
                    }
                    if sampling {
                        Image(decorative: photo, scale: 1).resizable().scaledToFit()
                            .overlay { GeometryReader { geo in Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
                                hex = PhotoColours.sample(photo, x: tap.location.x / geo.size.width, y: tap.location.y / geo.size.height)
                                sampling = false
                            }) } }.accessibilityLabel("Tap a colour in the photo")
                        Text("Tap a colour in the photo.").font(.footnote)
                    }
                    section("From your photo", colours: palette)
                    Text("Palettes").font(.subheadline).foregroundStyle(.secondary)
                    section("Paper & ink", colours: ["#FFFFFF", "#ECE8DF", "#D4C9B5", "#9C9284", "#242423"])
                    section("Earth", colours: ["#DFC7AE", "#B98767", "#914E3E", "#66775D", "#334538"])
                    HStack {
                        ColorPicker("Custom", selection: Binding(get: { Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0) }, set: { value in
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
                            hex = String(format: "#%02X%02X%02X", Int((r*255).rounded()), Int((g*255).rounded()), Int((b*255).rounded()))
                        }), supportsOpacity: false)
                        TextField("#RRGGBB", text: $hex).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced)).frame(width: 105).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Hex colour")
                        Button { sampling.toggle() } label: { Image(systemName: "eyedropper").frame(width: 44, height: 44) }.accessibilityLabel("Pick from photo")
                    }
                    section("Recent", colours: recent.split(separator: ",").map(String.init))
                }.padding(20)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") {
                        let colour = hex.uppercased()
                        recent = ([colour] + recent.split(separator: ",").map(String.init).filter { $0 != colour }).prefix(8).joined(separator: ",")
                        choose(colour); dismiss()
                    }.disabled(!valid) }
                }
        }.task { palette = PhotoColours.palette(photo) }
            .onChange(of: hex) { _, value in if valid { preview?(value.uppercased()) } }
    }
    private func section(_ name: String, colours: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                ForEach(colours, id: \.self) { c in Button { hex = c } label: {
                    RoundedRectangle(cornerRadius: 8).fill(Color(hex: UInt32(c.dropFirst(), radix: 16) ?? 0))
                        .frame(height: 40).overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.4)))
                        .overlay { if hex.uppercased() == c.uppercased() { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .black) } }
                }.buttonStyle(.plain).accessibilityLabel("Colour " + c).accessibilityAddTraits(hex == c ? .isSelected : []) }
            }
        }
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
