import SwiftUI

/// The Text panel (owner amendment 2026-10-11; mockup `textPanel`). With no layers, a 10 pt column: the lime "Add text"
/// pill and its note. With layers, an 8 pt column: the layer chips and "+ Add", the input box (opens the text sheet),
/// the eleven fonts, the Thin · Regular · Bold row, Size, the shared colour control and Opacity, all for the selected
/// layer.
struct TextPanelView: View {
    @Bindable var model: TextPanelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let layer = model.selectedLayer {
                VStack(alignment: .leading, spacing: 8) {
                    layerChips(selected: layer)
                    inputBox(layer)
                    fonts(layer)
                    weights(layer)
                    PanelSlider(label: "Size", value: layer.size, range: EditRecipe.TextLayer.sizeRange, identifier: "slider.size",
                                onChange: model.previewSize, onEnd: model.commitSize)
                    ColourControl(title: "Colour", selected: layer.colour, photo: model.session.originalImage, identifier: "text.colour",
                                  preview: model.previewColour, previewImage: { model.session.displayedImage },
                                  cancel: model.session.cancelLookPreview, choose: model.setColour)
                    PanelSlider(label: "Opacity", value: layer.opacity, range: 0...100, identifier: "slider.opacity",
                                onChange: model.previewOpacity, onEnd: model.commitOpacity)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    addTextButton
                    L2Note("Add text, then drag it anywhere on the photo. Pinch to resize or turn it.")
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { model.sheet != nil }, set: { if !$0 { model.cancelSheet() } })) {
            TextLayerEditor(text: model.sheetInitialText, commit: model.finishSheet, dismiss: model.cancelSheet)
                .presentationBackground(.clear)
        }
    }

    /// "Add text" (owner amendment 2026-10-11, second: smaller): a lime pill at the leading edge, not full width; 40 pt
    /// high, 20 pt corners, 16 pt side padding, the plus (16 pt) and the label (14 pt bold), 6 pt apart, in pill ink.
    private var addTextButton: some View {
        let c = L2(scheme: colorScheme)
        return Button(action: { presentWithoutCoverSlide(model.openAdd) }) {
            HStack(spacing: 6) {
                ApprovedIconView(icon: .plus, size: 16)
                Text("Add text").l2Text(14, weight: .bold)
            }
            .foregroundStyle(c(ApprovedColor.pillInk))
            .padding(.horizontal, 16).frame(height: 40)
            .background(Capsule().fill(c(ApprovedColor.pill)))
            .contentShape(Capsule())
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityIdentifier("text.add")
    }

    /// One chip per layer (36 pt, 18 pt corners, 12 pt padding, 13 pt semibold; the selected one on the lime pill, the
    /// others outlined in ink2; the layer's words on one line, truncated), then "+ Add" (14 pt plus, 4 pt gap).
    private func layerChips(selected: EditRecipe.TextLayer) -> some View {
        let c = L2(scheme: colorScheme)
        return ChipRow {
            ForEach(Array(model.layers.enumerated()), id: \.element.id) { index, layer in
                let isOn = layer.id == selected.id
                Button { model.select(layer.id) } label: {
                    Text(verbatim: layer.text.replacingOccurrences(of: "\n", with: " "))
                        .l2Text(13, weight: .semibold).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 180)
                        .fixedSize()
                        .foregroundStyle(isOn ? c(ApprovedColor.pillInk) : c(ApprovedColor.inkSecondary))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(Capsule().fill(isOn ? c(ApprovedColor.pill) : .clear))
                        .overlay { if !isOn { Capsule().strokeBorder(c(ApprovedColor.hairline), lineWidth: 1) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("text.layer.\(index + 1)")
            }
            if model.canAddLayer {
                Button(action: { presentWithoutCoverSlide(model.openAdd) }) {
                    HStack(spacing: 4) {
                        ApprovedIconView(icon: .plus, size: 14)
                        Text("Add").l2Text(13, weight: .semibold)
                    }
                    .foregroundStyle(c(ApprovedColor.inkSecondary))
                    .padding(.horizontal, 12).frame(height: 36)
                    .overlay(Capsule().strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityLabel(Text("Add text"))
                .accessibilityIdentifier("text.addMore")
            }
        }
    }

    /// The input box: at least 50 pt, 16 pt corners, chip fill, hairline, 14 pt padding; the selected layer's words at
    /// 17 pt in its own font and weight, the pencil (18 pt) trailing. Opens the text sheet.
    private func inputBox(_ layer: EditRecipe.TextLayer) -> some View {
        let c = L2(scheme: colorScheme)
        return Button(action: { presentWithoutCoverSlide(model.openEditSelected) }) {
            HStack {
                Text(verbatim: layer.text.replacingOccurrences(of: "\n", with: " "))
                    .font(Font(TextFonts.font(layer.font, weight: layer.weight, size: 17))).lineLimit(1)
                Spacer(minLength: 8)
                ApprovedIconView(icon: .pencil, size: 18)
            }
            .foregroundStyle(c(ApprovedColor.ink))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c(ApprovedColor.chip)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Edit text"))
        .accessibilityValue(Text(verbatim: layer.text))
        .accessibilityIdentifier("text.value")
    }

    /// The eleven fonts (`rowOf`, 8 pt gaps): at least 96×58, 16 pt corners, "Aa" at 20 pt in the font over its name
    /// (10.5 pt ink3, one line); the selected one with a 2 pt accent border, the others a hairline.
    private func fonts(_ layer: EditRecipe.TextLayer) -> some View {
        let c = L2(scheme: colorScheme)
        return ChipRow {
            ForEach(EditRecipe.TextLayer.Font.allCases, id: \.self) { font in
                let isOn = font == layer.font
                Button { model.chooseFont(font) } label: {
                    VStack(spacing: 2) {
                        Text(verbatim: "Aa").font(Font(TextFonts.font(font, size: 20))).foregroundStyle(c(ApprovedColor.ink))
                        Text(verbatim: font.rawValue).font(.system(size: 10.5)).foregroundStyle(c(ApprovedColor.inkTertiary))
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: 96, minHeight: 58)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.hairline), lineWidth: isOn ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: font.rawValue))
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("text.font.\(font.rawValue)")
            }
        }
    }

    /// Thin · Regular · Bold (owner amendment 2026-10-11, second; mockup `textPanel` `weights`): the `seg` look (4 pt
    /// padding, 22 pt corners, chip fill, three equal 36 pt segments 4 pt apart with 18 pt corners; the selected one on
    /// on-bg with on-ink text, the others ink2), each label at 14 pt in its own weight (200 / 400 / 700: system thin, regular, bold) whether selected
    /// or not. A single-weight font greys Thin and Bold (40 %) and they cannot be chosen.
    private func weights(_ layer: EditRecipe.TextLayer) -> some View {
        let c = L2(scheme: colorScheme)
        return HStack(spacing: 4) {
            ForEach(Self.weightOptions, id: \.weight) { option in
                let isOn = option.weight == layer.weight
                let isAvailable = TextPanelModel.isWeightAvailable(option.weight, for: layer.font)
                Button { model.chooseWeight(option.weight) } label: {
                    Text(option.title).l2Text(14, weight: option.fontWeight).lineLimit(1)
                        .foregroundStyle(isOn ? c(ApprovedColor.onInk) : c(ApprovedColor.inkSecondary))
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(Capsule().fill(isOn ? c(ApprovedColor.segmentSelected) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(UndimmedButtonStyle())
                .disabled(!isAvailable)
                .opacity(isAvailable ? 1 : 0.4)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("text.weight.\(option.weight.rawValue)")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c(ApprovedColor.chip)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Weight"))
    }

    private static var weightOptions: [(weight: EditRecipe.TextLayer.Weight, title: LocalizedStringKey, fontWeight: Font.Weight)] {
        [(.thin, "Thin", .thin), (.regular, "Regular", .regular), (.bold, "Bold", .bold)]
    }
}

/// The text sheet (mockup `textEdit` for the Text tool): sheetHead Cancel · "Text" · Done, then the field (at least
/// 52 pt, 16 pt corners, 2 pt accent border, 19 pt) with the keyboard below it, never covering it. Done is enabled once
/// the text is not blank.
struct TextLayerEditor: View {
    @FocusState private var focused: Bool
    @State var text: String
    let commit: (String) -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let c = L2(scheme: colorScheme)
        ApprovedSheetOverlay(isTablet: sizeClass == .regular, risesWithKeyboard: true, onDismiss: dismiss) {
            L2SheetHeader(title: Text("Text"),
                          leading: { L2TextButton(title: "Cancel", identifier: "text.sheet.cancel", action: dismiss) },
                          trailing: { L2TextButton(title: "Done", isBold: true,
                                                   isEnabled: !TextPanelModel.cleaned(text).isEmpty,
                                                   identifier: "text.sheet.done") { commit(text) } })
            TextField("", text: $text, axis: .vertical)
                .font(.system(size: 19)).lineLimit(1...4).focused($focused)
                .foregroundStyle(c(ApprovedColor.ink))
                .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c(ApprovedColor.selection), lineWidth: 2))
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                .accessibilityLabel(Text("Text"))
                .accessibilityIdentifier("text.sheet.field")
                .onChange(of: text) { _, value in
                    if value.count > EditRecipe.TextLayer.maximumTextLength { text = String(value.prefix(EditRecipe.TextLayer.maximumTextLength)) }
                }
        }
        .onAppear { focused = true }
    }
}
