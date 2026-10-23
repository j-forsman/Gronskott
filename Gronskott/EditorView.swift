import SwiftUI
import AppKit

private enum ExportFormat: String { case png, jpeg }

private final class BlurPreviewCache {
    var previews: [UUID: (CGRect, NSImage)] = [:]
}

struct EditorView: View {
    @State var image: NSImage

    // Drawing state
    @State private var elements: [DrawingElement] = []
    @State private var redoStack:  [DrawingElement] = []
    @State private var currentElement: DrawingElement?

    // Tool & style
    @State private var selectedTool:  DrawingTool   = .arrow
    @State private var selectedColorIndex: Int      = 0   // 0-7 = palette; 8 = custom
    @State private var customColor: Color           = .pink
    @State private var strokeWidth: CGFloat         = 3
    @State private var counterValue: Int            = 1
    @State private var isFilled:    Bool            = false
    @State private var hasShadow:   Bool            = false
    @State private var highlightMode: HighlightMode = .text
    @State private var blurMode:    BlurMode        = .pixelate
    @State private var opacity:    CGFloat         = 1.0
    @AppStorage("exportFormat") private var exportFormat: ExportFormat = .png
    @AppStorage("saveFolder") private var saveFolderPath: String = ""
    @State private var lastSavedURL: URL?

    // Drag-and-drop
    @State private var isDragTargeted: Bool         = false

    // Selection-tool state
    @State private var selectedElementID: UUID?     = nil
    @State private var moveAnchorImg: CGPoint       = .zero
    @State private var elementSnapshot: DrawingElement?
    @State private var resizeHandleIdx: Int?        = nil
    @State private var resizeSnapshot: DrawingElement?

    // Text-tool state
    @State private var showingTextInput = false
    @State private var pendingElement: DrawingElement?   // text or bubble waiting for its text
    @State private var textInputValue   = ""
    @State private var editingTextID: UUID? = nil

    // Blur preview cache (reference type so Canvas closure can write without SwiftUI state changes)
    @State private var blurCache = BlurPreviewCache()

    // Crop-tool state
    @State private var cropRect: CGRect? = nil      // image-pixel coords

    var selectedColor: Color {
        selectedColorIndex < paletteColors.count ? paletteColors[selectedColorIndex] : customColor
    }

    var body: some View {
        HStack(spacing: 0) {
            leftToolbar
            Divider()
            VStack(spacing: 0) {
                topBar
                Divider()
                canvasArea
                Divider()
                statusBar
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(keyboardShortcutOverlay)
        .alert(textPromptTitle, isPresented: $showingTextInput) {
            TextField("Din text...", text: $textInputValue)
            Button(editingTextID == nil ? "Lägg till" : "Uppdatera") { commitText() }
            Button(pendingElement?.tool == .speechBubble ? "Utan text" : "Avbryt", role: .cancel) {
                textInputValue = ""; commitText()
            }
        }
        .onChange(of: image.size) { _, _ in blurCache.previews.removeAll() }
    }

    // MARK: - Keyboard shortcuts (hidden buttons)

    private var keyboardShortcutOverlay: some View {
        Group {
            ForEach(DrawingTool.allCases) { tool in
                if let sc = tool.shortcut {
                    Button("") { selectTool(tool) }
                        .keyboardShortcut(sc, modifiers: [])
                        .hidden()
                }
            }
            Button("") { saveImage() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
            Button("") { saveImageAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .hidden()
            Button("") { deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
            Button("") { duplicateSelected() }
                .keyboardShortcut("d", modifiers: .command)
                .hidden()
            // Arrow nudge — 1 px; 10 px with Shift
            Button("") { nudge(dx: -1,  dy: 0)  }.keyboardShortcut(.leftArrow,  modifiers: []).hidden()
            Button("") { nudge(dx:  1,  dy: 0)  }.keyboardShortcut(.rightArrow, modifiers: []).hidden()
            Button("") { nudge(dx: 0,  dy: -1)  }.keyboardShortcut(.upArrow,    modifiers: []).hidden()
            Button("") { nudge(dx: 0,  dy:  1)  }.keyboardShortcut(.downArrow,  modifiers: []).hidden()
            Button("") { nudge(dx: -10, dy: 0)  }.keyboardShortcut(.leftArrow,  modifiers: .shift).hidden()
            Button("") { nudge(dx:  10, dy: 0)  }.keyboardShortcut(.rightArrow, modifiers: .shift).hidden()
            Button("") { nudge(dx: 0,  dy: -10) }.keyboardShortcut(.upArrow,    modifiers: .shift).hidden()
            Button("") { nudge(dx: 0,  dy:  10) }.keyboardShortcut(.downArrow,  modifiers: .shift).hidden()
        }
    }

    // MARK: - Left vertical toolbar (tool selection)

    private var leftToolbar: some View {
        VStack(spacing: 2) {
            toolBtn(.select)
            Divider().padding(.vertical, 2)
            toolBtn(.arrow)
            toolBtn(.line)
            toolBtn(.rect)
            toolBtn(.roundedRect)
            toolBtn(.ellipse)
            toolBtn(.pen)
            toolBtn(.speechBubble)
            Divider().padding(.vertical, 2)
            toolBtn(.highlight)
            toolBtn(.text)
            toolBtn(.blur)
            toolBtn(.counter)
            Divider().padding(.vertical, 2)
            toolBtn(.crop)
            Spacer()
        }
        .padding(4)
        .frame(width: 66)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Top options bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { _ = copyToClipboard() } label: {
                Label("Kopiera", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("c", modifiers: .command)
            .help("Kopiera till urklipp ⌘C")

            Button { copyAndCloseWindow() } label: {
                Label("Kopiera & stäng", systemImage: "checkmark.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Kopiera till urklipp och stäng fönstret ⌘⇧C")

            Menu {
                Button("Spara som… ⇧⌘S") { saveImageAs() }
                Divider()
                Picker("Format", selection: $exportFormat) {
                    Text("PNG").tag(ExportFormat.png)
                    Text("JPEG").tag(ExportFormat.jpeg)
                }
                .pickerStyle(.inline)
                Divider()
                Button(saveFolderPath.isEmpty ? "Välj sparmapp…" : "Byt sparmapp…") { chooseSaveFolder() }
            } label: {
                Label("Spara", systemImage: "square.and.arrow.down")
            } primaryAction: {
                saveImage()
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help(saveFolderPath.isEmpty
                  ? "Spara ⌘S — välj en sparmapp första gången"
                  : "Spara i \((saveFolderPath as NSString).abbreviatingWithTildeInPath) ⌘S")

            Divider().frame(height: 20)
            colorPalette
            Divider().frame(height: 20)
            strokeControl
            contextualControls
            effectsMenu
            Spacer(minLength: 0)
            undoRedoGroup
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 40)
    }

    private func toolBtn(_ tool: DrawingTool) -> some View {
        Button {
            selectTool(tool)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 16)
                Text(tool.label)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selectedTool == tool ? Color.accentColor : Color.primary)
            .frame(width: 56, height: 38)
            .overlay(alignment: .topTrailing) {
                if let key = shortcutKey(tool) {
                    Text(key)
                        .font(.system(size: 7, weight: .semibold).monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selectedTool == tool ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selectedTool == tool ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(shortcutHelp(tool))
    }

    private func selectTool(_ tool: DrawingTool) {
        selectedTool = tool
        if tool != .select { selectedElementID = nil }
        if tool == .highlight { selectedColorIndex = 2 }
    }

    private func shortcutKey(_ tool: DrawingTool) -> String? {
        guard let sc = tool.shortcut else { return nil }
        return sc == .escape ? "Esc" : String(sc.character).uppercased()
    }

    private func shortcutHelp(_ tool: DrawingTool) -> String {
        guard let key = shortcutKey(tool) else { return tool.label }
        return "\(tool.label) (\(key))"
    }

    private var colorPalette: some View {
        HStack(spacing: 4) {
            ForEach(paletteColors.indices, id: \.self) { idx in
                Button {
                    selectedColorIndex = idx
                } label: {
                    ZStack {
                        Circle().fill(paletteColors[idx])
                            .frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.2), radius: 1)
                        if selectedColorIndex == idx {
                            Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                                .frame(width: 20, height: 20)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Custom color swatch — ColorPicker opens the native color panel
            ZStack {
                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 20, height: 20)
                    .simultaneousGesture(TapGesture().onEnded { selectedColorIndex = 8 })
                if selectedColorIndex == 8 {
                    Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                        .frame(width: 20, height: 20)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var strokeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "lineweight").font(.caption).foregroundStyle(.secondary)
            Slider(value: $strokeWidth, in: 1...14, step: 1).frame(width: 72)
            Text("\(Int(strokeWidth))").font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 16)
        }
    }

    // Context-sensitive: fill, shadow, highlight mode, blur mode, counter reset
    @ViewBuilder
    private var contextualControls: some View {
        if selectedTool.isShapeWithFill || selectedTool == .speechBubble {
            Divider().frame(height: 20)
            Toggle(isOn: $isFilled) { Label("Fyll", systemImage: "square.fill") }
                .toggleStyle(.button).controlSize(.small)
        }
        if selectedTool != .select && selectedTool != .crop {
            Toggle(isOn: $hasShadow) { Label("Skugga", systemImage: "shadow") }
                .toggleStyle(.button).controlSize(.small)
            Divider().frame(height: 20)
            HStack(spacing: 4) {
                Image(systemName: "circle.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                Slider(value: $opacity, in: 0.1...1.0).frame(width: 60)
                Text("\(Int(opacity * 100))%").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        }
        if selectedTool == .highlight {
            Divider().frame(height: 20)
            Picker("", selection: $highlightMode) {
                ForEach(HighlightMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .controlSize(.small)
        }
        if selectedTool == .blur {
            Divider().frame(height: 20)
            Picker("", selection: $blurMode) {
                ForEach(BlurMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .controlSize(.small)
        }
        if selectedTool == .counter {
            Divider().frame(height: 20)
            Text("#\(counterValue)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Nollställ") { counterValue = 1 }
                .buttonStyle(.bordered).controlSize(.mini)
        }
    }

    private var effectsMenu: some View {
        Menu {
            Section("Bildeffekter") {
                ForEach(ImageEffect.allCases, id: \.self) { fx in
                    Button { applyEffect(fx) } label: { Label(fx.label, systemImage: fx.icon) }
                }
            }
            Divider()
            Section("Redigera") {
                Button("Autobeskär") { autoCrop() }
                Button("Ändra storlek…") { resizeImage() }
            }
        } label: {
            Label("Effekter", systemImage: "wand.and.stars").font(.system(size: 11))
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
    }

    private var undoRedoGroup: some View {
        HStack(spacing: 4) {
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(elements.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .help("Ångra ⌘Z")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Gör om ⇧⌘Z")
        }
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                Color(NSColor.underPageBackgroundColor)

                // Base image
                let (drawSize, offset) = imageLayout(in: geo.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drawSize.width, height: drawSize.height)
                    .position(x: offset.x + drawSize.width / 2, y: offset.y + drawSize.height / 2)

                // Drawing canvas
                Canvas { ctx, size in
                    let (drawSize, offset) = imageLayout(in: size)
                    let scale = drawSize.width / image.size.width
                    let resolvedBase = ctx.resolve(Image(nsImage: image))
                    var c = ctx
                    c.translateBy(x: offset.x, y: offset.y)
                    c.scaleBy(x: scale, y: scale)

                    // Highlight-area mode: darken outside selection
                    for el in elements where el.tool == .highlight && el.highlightMode == .area {
                        renderHighlightArea(el, in: &c, imageSize: image.size)
                    }

                    for el in elements { renderElement(el, in: &c, resolvedBase: resolvedBase) }
                    if let el = currentElement { renderElement(el, in: &c) }

                    // Crop overlay
                    if selectedTool == .crop, let cr = cropRect {
                        renderCropOverlay(cr, imageSize: image.size, in: &c)
                    }

                    // Selection indicator
                    if selectedTool == .select,
                       let selID = selectedElementID,
                       let el = elements.first(where: { $0.id == selID }) {
                        renderSelectionIndicator(el, in: &c)
                    }
                }

                // Gesture layer
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in handleDragChanged(v, in: geo.size) }
                            .onEnded   { v in handleDragEnded(v,   in: geo.size) }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { val in handleDoubleTap(at: val.location, in: geo.size) }
                    )
                RightClickCatcher { elementMenu(at: $0, in: geo.size) }

                // Crop confirm overlay
                if selectedTool == .crop, let cr = cropRect {
                    cropConfirmBar(cr, containerSize: geo.size)
                }

                // Drag-and-drop target indicator
                if isDragTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let img = NSImage(contentsOf: url) else { return false }
                image = img
                elements.removeAll()
                redoStack.removeAll()
                selectedElementID = nil
                return true
            } isTargeted: { isDragTargeted = $0 }
        }
    }

    // MARK: - Render elements

    private func renderElement(_ el: DrawingElement, in ctx: inout GraphicsContext,
                                resolvedBase: GraphicsContext.ResolvedImage? = nil) {
        // Skip highlight-area, handled separately
        if el.tool == .highlight && el.highlightMode == .area { return }

        let color = el.effectiveColor
        let stroke = StrokeStyle(lineWidth: el.strokeWidth, lineCap: .round, lineJoin: .round)

        ctx.drawLayer { layerCtx in
            if el.opacity < 1.0 {
                layerCtx.addFilter(.colorMultiply(Color(white: 1, opacity: el.opacity)))
            }
            if el.hasShadow {
                layerCtx.drawLayer { shadowCtx in
                    shadowCtx.addFilter(.shadow(color: .black.opacity(0.55), radius: 4, x: 3, y: 3))
                    draw(el, color: color, stroke: stroke, resolvedBase: resolvedBase, in: &shadowCtx)
                }
            } else {
                draw(el, color: color, stroke: stroke, resolvedBase: resolvedBase, in: &layerCtx)
            }
        }
    }

    private func draw(_ el: DrawingElement, color: Color, stroke: StrokeStyle,
                      resolvedBase: GraphicsContext.ResolvedImage? = nil,
                      in ctx: inout GraphicsContext) {
        switch el.tool {
        case .select, .crop: break

        case .arrow:
            renderArrow(el, color: color, in: &ctx)

        case .line:
            var p = Path(); p.move(to: el.start); p.addLine(to: el.end)
            ctx.stroke(p, with: .color(color), style: stroke)

        case .rect:
            let r = el.boundingRect
            if el.isFilled { ctx.fill(Path(r), with: .color(color)) }
            else            { ctx.stroke(Path(r), with: .color(color), style: stroke) }

        case .roundedRect:
            let r = el.boundingRect
            let cr = min(r.width, r.height) * 0.18
            let p = Path(roundedRect: r, cornerRadius: cr)
            if el.isFilled { ctx.fill(p, with: .color(color)) }
            else            { ctx.stroke(p, with: .color(color), style: stroke) }

        case .ellipse:
            let r = el.boundingRect
            if el.isFilled { ctx.fill(Path(ellipseIn: r), with: .color(color)) }
            else            { ctx.stroke(Path(ellipseIn: r), with: .color(color), style: stroke) }

        case .pen:
            guard el.points.count > 1 else { break }
            var p = Path()
            p.move(to: el.points[0])
            el.points.dropFirst().forEach { p.addLine(to: $0) }
            ctx.stroke(p, with: .color(color), style: stroke)

        case .speechBubble:
            renderSpeechBubble(el, color: color, stroke: stroke, in: &ctx)

        case .highlight:
            let r = el.boundingRect
            ctx.fill(Path(r), with: .color(color.opacity(0.38)))

        case .text:
            if el.text.isEmpty, let box = el.textBox {
                // Box being dragged out, before the text prompt
                ctx.stroke(Path(box), with: .color(color.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            renderText(el, in: &ctx)

        case .blur:
            renderBlurPreview(el, in: &ctx)

        case .counter:
            renderCounter(el, color: color, in: &ctx)
        }
    }

    private func renderArrow(_ el: DrawingElement, color: Color, in ctx: inout GraphicsContext) {
        guard el.start != el.end else { return }
        var p = Path()
        p.move(to: el.start); p.addLine(to: el.end)
        let angle   = atan2(el.end.y - el.start.y, el.end.x - el.start.x)
        let headLen = max(14, el.strokeWidth * 4.5)
        let spread: CGFloat = .pi / 6
        let a1 = CGPoint(x: el.end.x - headLen * cos(angle - spread),
                         y: el.end.y - headLen * sin(angle - spread))
        let a2 = CGPoint(x: el.end.x - headLen * cos(angle + spread),
                         y: el.end.y - headLen * sin(angle + spread))
        p.move(to: el.end); p.addLine(to: a1)
        p.move(to: el.end); p.addLine(to: a2)
        ctx.stroke(p, with: .color(color),
                   style: StrokeStyle(lineWidth: el.strokeWidth, lineCap: .round))
    }

    private func renderSpeechBubble(_ el: DrawingElement, color: Color,
                                    stroke: StrokeStyle, in ctx: inout GraphicsContext) {
        let r = el.boundingRect
        guard r.width > 4, r.height > 4 else { return }
        let cr: CGFloat = min(r.width, r.height) * 0.15
        let body = Path(roundedRect: r, cornerRadius: cr)

        let tw: CGFloat = max(12, r.width * 0.18)
        let th: CGFloat = max(14, r.height * 0.28)
        let cx = r.midX
        var tail = Path()
        tail.move(to: CGPoint(x: cx - tw/2, y: r.maxY))
        tail.addLine(to: CGPoint(x: cx, y: r.maxY + th))
        tail.addLine(to: CGPoint(x: cx + tw/2, y: r.maxY))
        tail.closeSubpath()

        if el.isFilled {
            ctx.fill(body,  with: .color(color))
            ctx.fill(tail,  with: .color(color))
        } else {
            ctx.stroke(body, with: .color(color), style: stroke)
            ctx.stroke(tail, with: .color(color), style: stroke)
        }
        renderText(el, in: &ctx)
    }

    // Same layout rules as ImageExporter.drawText: wrap inside textBox, bubbles centre the block.
    private func renderText(_ el: DrawingElement, in ctx: inout GraphicsContext) {
        guard !el.text.isEmpty else { return }
        let text = ctx.resolve(Text(el.text).font(.system(size: el.fontSize, weight: .bold))
            .foregroundColor(el.textColor))
        guard let box = el.textBox else {
            ctx.draw(text, at: el.start, anchor: .topLeading)
            return
        }
        let sz = text.measure(in: box.size)
        let origin = el.tool == .speechBubble
            ? CGPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2)
            : box.origin
        ctx.draw(text, in: CGRect(origin: origin, size: CGSize(width: sz.width, height: min(sz.height, box.height))))
    }

    private func renderBlurPreview(_ el: DrawingElement, in ctx: inout GraphicsContext) {
        let r = el.boundingRect
        if el.blurMode == .redact {
            ctx.fill(Path(r), with: .color(.black))
            return
        }
        let cached = blurCache.previews[el.id]
        let preview: NSImage?
        if let (cachedRect, cachedImg) = cached, cachedRect == r {
            preview = cachedImg
        } else {
            preview = makeBlurPreview(el)
            if let preview { blurCache.previews[el.id] = (r, preview) }
        }
        if let preview {
            ctx.draw(ctx.resolve(Image(nsImage: preview)), in: r)
        } else {
            ctx.fill(Path(r), with: .color(.black.opacity(0.40)))
            ctx.stroke(Path(r), with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    private func makeBlurPreview(_ el: DrawingElement) -> NSImage? {
        guard let cgSrc = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let r = el.boundingRect
        guard r.width > 1, r.height > 1 else { return nil }

        let pxScaleX = CGFloat(cgSrc.width)  / image.size.width
        let pxScaleY = CGFloat(cgSrc.height) / image.size.height
        let srcBounds = CGRect(x: 0, y: 0, width: CGFloat(cgSrc.width), height: CGFloat(cgSrc.height))
        let pixelRect = CGRect(x: r.minX * pxScaleX, y: r.minY * pxScaleY,
                               width: r.width * pxScaleX, height: r.height * pxScaleY)
                              .intersection(srcBounds)
        guard pixelRect.width > 0, pixelRect.height > 0,
              let crop = cgSrc.cropping(to: pixelRect) else { return nil }

        let ciSrc = CIImage(cgImage: crop)
        let filtered: CIImage
        if el.blurMode == .pixelate {
            filtered = ciSrc.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(4.0, 10.0 * pxScaleX),
                kCIInputCenterKey: CIVector(x: ciSrc.extent.minX, y: ciSrc.extent.minY)
            ])
        } else {
            filtered = ciSrc.clampedToExtent()
                           .applyingFilter("CIGaussianBlur",
                                           parameters: [kCIInputRadiusKey: 7.0 * pxScaleX])
                           .cropped(to: ciSrc.extent)
        }
        guard let cgResult = ImageExporter.ciContext.createCGImage(filtered, from: ciSrc.extent) else { return nil }
        return NSImage(cgImage: cgResult, size: r.size)
    }

    private func renderCounter(_ el: DrawingElement, color: Color, in ctx: inout GraphicsContext) {
        let r = max(15, el.strokeWidth * 4)
        let circ = CGRect(x: el.start.x - r, y: el.start.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: circ), with: .color(color))
        ctx.stroke(Path(ellipseIn: circ), with: .color(.white.opacity(0.5)),
                   style: StrokeStyle(lineWidth: 1.5))
        let textColor: Color = el.colorIndex == 6 ? .black : .white
        ctx.draw(Text(String(el.counter)).font(.system(size: r * 0.95, weight: .bold))
            .foregroundColor(textColor), at: el.start)
    }

    private func renderHighlightArea(_ el: DrawingElement, in ctx: inout GraphicsContext,
                                     imageSize: CGSize) {
        let r = el.boundingRect
        // Darken full image, then cut out the highlighted rect
        ctx.drawLayer { c in
            var dark = Path()
            dark.addRect(CGRect(origin: .zero, size: imageSize))
            dark.addRect(r)
            c.fill(dark, with: .color(.black.opacity(0.5)),
                   style: FillStyle(eoFill: true))
        }
    }

    private func renderCropOverlay(_ cropR: CGRect, imageSize: CGSize, in ctx: inout GraphicsContext) {
        // Dim outside crop
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: imageSize))
        path.addRect(cropR)
        ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        // Dashed border
        ctx.stroke(Path(cropR), with: .color(.white),
                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        // Corner handles
        let hs: CGFloat = 10
        for corner in cropCorners(cropR) {
            let handle = CGRect(x: corner.x - hs/2, y: corner.y - hs/2, width: hs, height: hs)
            ctx.fill(Path(handle), with: .color(.white))
        }
    }

    private func cropCorners(_ r: CGRect) -> [CGPoint] {
        [r.origin,
         CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY),
         CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func renderSelectionIndicator(_ el: DrawingElement, in ctx: inout GraphicsContext) {
        let r = el.boundingRect.insetBy(dx: -6, dy: -6)
        ctx.stroke(Path(r), with: .color(.blue.opacity(0.8)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        guard el.supportsResize else { return }
        let hs: CGFloat = 8
        for corner in cropCorners(r) {
            let h = CGRect(x: corner.x - hs/2, y: corner.y - hs/2, width: hs, height: hs)
            ctx.fill(Path(h), with: .color(.white))
            ctx.stroke(Path(h), with: .color(.blue.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.5))
        }
    }

    // MARK: - Crop confirm bar

    private func cropConfirmBar(_ cropR: CGRect, containerSize: CGSize) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    applyCrop(cropR)
                } label: {
                    Label("Bekräfta beskärning", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)

                Button("Avbryt") {
                    cropRect = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 16)
        }
    }

    // MARK: - Coordinate helpers

    private func imageLayout(in size: CGSize) -> (drawSize: CGSize, offset: CGPoint) {
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else { return (.zero, .zero) }
        // Never upscale: at 1:1 each image point lands on a screen point, so it stays crisp.
        // Whole-point offset avoids half-pixel resampling.
        let scale = min(1, size.width / iw, size.height / ih)
        let dw = iw * scale, dh = ih * scale
        return (CGSize(width: dw, height: dh),
                CGPoint(x: ((size.width - dw) / 2).rounded(), y: ((size.height - dh) / 2).rounded()))
    }

    private func toImageCoords(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let (ds, off) = imageLayout(in: size)
        let scale = ds.width / image.size.width
        return CGPoint(x: (p.x - off.x) / scale, y: (p.y - off.y) / scale)
    }

    // MARK: - Gesture handling

    private func handleDragChanged(_ val: DragGesture.Value, in size: CGSize) {
        switch selectedTool {
        case .select:
            handleSelectDrag(val, in: size)
        case .crop:
            handleCropDrag(val, in: size)
        default:
            if currentElement == nil, elementSnapshot == nil,
               let el = movableElement(at: toImageCoords(val.startLocation, in: size)) {
                selectedElementID = el.id
                moveAnchorImg     = toImageCoords(val.startLocation, in: size)
                elementSnapshot   = el
            }
            if elementSnapshot != nil { handleSelectDrag(val, in: size) }
            else                      { handleDrawDrag(val, in: size) }
        }
    }

    // Drag existing items without switching to Välj: text with the text tool, anything with ⌘.
    private func movableElement(at p: CGPoint) -> DrawingElement? {
        guard let el = elements.last(where: { $0.hitTest(p) }) else { return nil }
        if NSEvent.modifierFlags.contains(.command) { return el }
        return selectedTool == .text && el.tool == .text ? el : nil
    }

    private func handleDragEnded(_ val: DragGesture.Value, in size: CGSize) {
        switch selectedTool {
        case .select:
            elementSnapshot = nil
            resizeSnapshot  = nil
            resizeHandleIdx = nil

        case .crop:
            break  // cropRect stays set; user confirms via button

        default:
            if elementSnapshot != nil { elementSnapshot = nil; return }
            finalizeDrawing(val, in: size)
        }
    }

    // SELECT tool

    private func handleSelectDrag(_ val: DragGesture.Value, in size: CGSize) {
        let startImg = toImageCoords(val.startLocation, in: size)
        let curImg   = toImageCoords(val.location, in: size)

        if elementSnapshot == nil && resizeSnapshot == nil {
            // Check corner handles of the selected element first
            if let selID = selectedElementID,
               let el = elements.first(where: { $0.id == selID }),
               el.supportsResize {
                let r = el.boundingRect.insetBy(dx: -6, dy: -6)
                let hs: CGFloat = 12   // larger hit area than the 8pt visual
                for (idx, corner) in cropCorners(r).enumerated() {
                    let handle = CGRect(x: corner.x - hs/2, y: corner.y - hs/2, width: hs, height: hs)
                    if handle.contains(startImg) {
                        resizeHandleIdx = idx
                        resizeSnapshot  = el
                        return
                    }
                }
            }
            // Not on a handle — start a move or deselect
            if let el = elements.last(where: { $0.hitTest(startImg) }) {
                selectedElementID = el.id
                moveAnchorImg     = startImg
                elementSnapshot   = el
            } else {
                selectedElementID = nil
            }
        }

        // Resize path
        if let handleIdx = resizeHandleIdx, let orig = resizeSnapshot,
           let idx = elements.firstIndex(where: { $0.id == orig.id }) {
            var updated = orig
            updated.resize(handleIdx: handleIdx, movingTo: curImg)
            elements[idx] = updated
            return
        }

        // Move path
        guard let snap = elementSnapshot,
              let idx  = elements.firstIndex(where: { $0.id == snap.id }) else { return }
        let delta = curImg - moveAnchorImg
        var moved = snap
        moved.move(by: delta)
        elements[idx] = moved
    }

    // CROP tool

    private func handleCropDrag(_ val: DragGesture.Value, in size: CGSize) {
        let s = toImageCoords(val.startLocation, in: size)
        let c = toImageCoords(val.location,      in: size)
        let clamped = CGPoint(
            x: max(0, min(c.x, image.size.width)),
            y: max(0, min(c.y, image.size.height))
        )
        cropRect = CGRect(
            x: min(s.x, clamped.x), y: min(s.y, clamped.y),
            width: abs(clamped.x - s.x), height: abs(clamped.y - s.y)
        )
    }

    // DRAW tools

    private func handleDrawDrag(_ val: DragGesture.Value, in size: CGSize) {
        let startImg = toImageCoords(val.startLocation, in: size)
        let curImg   = toImageCoords(val.location,      in: size)

        if currentElement == nil {
            let isCustom = selectedColorIndex >= paletteColors.count
            var el = DrawingElement(
                tool: selectedTool, start: startImg, end: curImg,
                colorIndex: isCustom ? 0 : selectedColorIndex,
                customColor: isCustom ? customColor : nil,
                strokeWidth: strokeWidth,
                isFilled: isFilled, hasShadow: hasShadow,
                highlightMode: highlightMode, blurMode: blurMode,
                opacity: opacity
            )
            if selectedTool == .pen     { el.points = [startImg] }
            if selectedTool == .counter { el.counter = counterValue }
            currentElement = el
        } else {
            currentElement?.end = curImg
            if selectedTool == .pen { currentElement?.points.append(curImg) }
        }
        redoStack.removeAll()
    }

    private func finalizeDrawing(_ val: DragGesture.Value, in size: CGSize) {
        guard var el = currentElement else { return }
        let endImg = toImageCoords(val.location, in: size)
        el.end = endImg
        if selectedTool == .pen { el.points.append(endImg) }
        currentElement = nil

        let dx = abs(el.end.x - el.start.x)
        let dy = abs(el.end.y - el.start.y)

        if selectedTool == .text || (selectedTool == .speechBubble && (dx > 2 || dy > 2)) {
            if el.tool == .text && el.textBox == nil { el.end = el.start }  // plain click = point text
            pendingElement   = el
            textInputValue   = ""
            showingTextInput = true
            return
        }

        if selectedTool == .counter || dx > 2 || dy > 2 || selectedTool == .pen {
            elements.append(el)
            if selectedTool == .counter { counterValue += 1 }
        }
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        let imgPt = toImageCoords(location, in: size)
        guard let el = elements.last(where: { $0.hitTest(imgPt) }),
              el.tool == .text || el.tool == .speechBubble else { return }
        beginEditingText(el)
    }

    private var textPromptTitle: String {
        let isBubble = (pendingElement ?? elements.first { $0.id == editingTextID })?.tool == .speechBubble
        if isBubble { return "Text i pratbubblan (valfritt)" }
        return editingTextID == nil ? "Ange text" : "Redigera text"
    }

    private func beginEditingText(_ el: DrawingElement) {
        editingTextID     = el.id
        textInputValue    = el.text
        selectedElementID = el.id
        showingTextInput  = true
    }

    // Also the cancel path (called with empty text): an empty text element is dropped,
    // an empty bubble is kept as a plain bubble.
    private func commitText() {
        let value = textInputValue
        if let editID = editingTextID, let idx = elements.firstIndex(where: { $0.id == editID }) {
            if !value.isEmpty || elements[idx].tool == .speechBubble {
                elements[idx].text = value
            }
        } else if var el = pendingElement, !(el.tool == .text && value.isEmpty) {
            el.text = value
            elements.append(el)
            redoStack.removeAll()
        }
        pendingElement = nil; editingTextID = nil; textInputValue = ""
    }

    // MARK: - Right-click menu

    private func elementMenu(at viewPt: CGPoint, in size: CGSize) -> NSMenu? {
        guard let el = elements.last(where: { $0.hitTest(toImageCoords(viewPt, in: size)) }) else { return nil }
        let id = el.id
        func change(_ edit: @escaping (inout DrawingElement) -> Void) -> () -> Void {
            {
                guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
                edit(&elements[i])
                redoStack.removeAll()
            }
        }

        let menu = NSMenu()
        if el.tool == .text || el.tool == .speechBubble {
            menu.addItem(ClosureMenuItem(el.text.isEmpty ? "Lägg till text…" : "Redigera text…") {
                beginEditingText(el)
            })
            menu.addItem(.separator())
        }

        let colorNames = ["Röd", "Orange", "Gul", "Grön", "Blå", "Lila", "Vit", "Svart"]
        let colors = NSMenu()
        for idx in paletteColors.indices {
            let name = idx < colorNames.count ? colorNames[idx] : "Färg \(idx + 1)"
            colors.addItem(ClosureMenuItem(name, checked: el.customColor == nil && el.colorIndex == idx,
                                           image: swatch(paletteColors[idx]),
                                           handler: change { $0.colorIndex = idx; $0.customColor = nil }))
        }
        let colorItem = NSMenuItem(title: "Färg", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        if el.tool != .blur && el.tool != .highlight {
            let sizes = NSMenu()
            for w: CGFloat in [1, 2, 3, 5, 8, 12] {
                sizes.addItem(ClosureMenuItem("\(Int(w))", checked: el.strokeWidth == w,
                                              handler: change { $0.strokeWidth = w }))
            }
            let sizeItem = NSMenuItem(title: el.tool == .text ? "Textstorlek" : "Tjocklek",
                                      action: nil, keyEquivalent: "")
            sizeItem.submenu = sizes
            menu.addItem(sizeItem)
            if el.tool.isShapeWithFill {
                menu.addItem(ClosureMenuItem("Fyll", checked: el.isFilled, handler: change { $0.isFilled.toggle() }))
            }
            menu.addItem(ClosureMenuItem("Skugga", checked: el.hasShadow, handler: change { $0.hasShadow.toggle() }))
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Lägg längst fram") {
            guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
            elements.append(elements.remove(at: i))
        })
        menu.addItem(ClosureMenuItem("Lägg längst bak") {
            guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
            elements.insert(elements.remove(at: i), at: 0)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Duplicera") { selectedElementID = id; duplicateSelected() })
        menu.addItem(ClosureMenuItem("Ta bort") { selectedElementID = id; deleteSelected() })
        return menu
    }

    private func swatch(_ color: Color) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            NSColor(color).setFill(); p.fill()
            NSColor.separatorColor.setStroke(); p.stroke()
            return true
        }
    }

    // MARK: - Actions

    private func undo() {
        guard let last = elements.last else { return }
        redoStack.append(last)
        elements.removeLast()
        if last.tool == .counter { counterValue = max(1, counterValue - 1) }
        if selectedElementID == last.id { selectedElementID = nil }
    }

    private func redo() {
        guard let last = redoStack.last else { return }
        elements.append(last)
        redoStack.removeLast()
        if last.tool == .counter { counterValue += 1 }
    }

    private func deleteSelected() {
        guard let id = selectedElementID,
              let idx = elements.firstIndex(where: { $0.id == id }) else { return }
        redoStack.removeAll()
        elements.remove(at: idx)
        selectedElementID = nil
    }

    private func duplicateSelected() {
        guard let id = selectedElementID,
              let el = elements.first(where: { $0.id == id }) else { return }
        var copy = el.duplicated()
        copy.move(by: CGPoint(x: 10, y: 10))
        elements.append(copy)
        selectedElementID = copy.id
        redoStack.removeAll()
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard selectedTool == .select,
              let id = selectedElementID,
              let idx = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[idx].move(by: CGPoint(x: dx, y: dy))
        redoStack.removeAll()
    }

    private func applyCrop(_ rect: CGRect) {
        guard rect.width > 4, rect.height > 4 else { cropRect = nil; return }

        // cgImage.cropping(to:) takes pixel coordinates; rect is in logical points.
        // Scale to pixel space to handle Retina displays correctly.
        if let cgSrc = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let sx = CGFloat(cgSrc.width)  / image.size.width
            let sy = CGFloat(cgSrc.height) / image.size.height
            let pixelRect = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                                   width: rect.width * sx, height: rect.height * sy)
            if let cropped = cgSrc.cropping(to: pixelRect) {
                image = NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
            }
        }

        // Shift elements by -rect.origin
        let origin = rect.origin
        elements = elements.map { el in
            var e = el
            e.move(by: CGPoint(x: -origin.x, y: -origin.y))
            return e
        }
        cropRect = nil
    }

    private func autoCrop() {
        // Trim 1px solid border as a baseline (CITrimFilter not available on all systems)
        let inset: CGFloat = 1
        let rect = CGRect(x: inset, y: inset,
                          width: image.size.width - inset * 2,
                          height: image.size.height - inset * 2)
        applyCrop(rect)
    }

    private func resizeImage() {
        let alert = NSAlert()
        alert.messageText = "Ändra storlek"
        alert.informativeText = "Ange ny bredd i pixlar (proportioner behålls):"
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "\(Int(image.size.width))"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Avbryt")
        guard alert.runModal() == .alertFirstButtonReturn,
              let newW = Double(field.stringValue), newW > 0 else { return }
        let ratio = newW / Double(image.size.width)
        let newH = Double(image.size.height) * ratio
        let newSize = NSSize(width: newW, height: newH)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resized.unlockFocus()
        image = resized
        elements = elements.map { el in
            var e = el
            e.start = CGPoint(x: e.start.x * ratio, y: e.start.y * ratio)
            e.end   = CGPoint(x: e.end.x   * ratio, y: e.end.y   * ratio)
            e.points = e.points.map { CGPoint(x: $0.x * ratio, y: $0.y * ratio) }
            return e
        }
    }

    private func applyEffect(_ fx: ImageEffect) {
        guard let result = ImageExporter.applyEffect(fx, to: image) else { return }
        image = result
    }

    private var saveFolderURL: URL? {
        saveFolderPath.isEmpty ? nil : URL(fileURLWithPath: saveFolderPath, isDirectory: true)
    }

    private var fileExtension: String { exportFormat == .png ? "png" : "jpg" }

    // Spara: straight into the chosen folder with a timestamped name (asks for a folder the first time).
    private func saveImage() {
        guard let folder = saveFolderURL ?? chooseSaveFolder() else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'kl.' HH.mm.ss"
        let base = "Skärmdump \(df.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(fileExtension)")
            n += 1
        }
        writeImage(to: url)
    }

    private func saveImageAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = exportFormat == .png ? [.png] : [.jpeg]
        panel.nameFieldStringValue = "skärmdump.\(fileExtension)"
        panel.directoryURL = saveFolderURL
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeImage(to: url)
    }

    @discardableResult
    private func chooseSaveFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Välj"
        panel.message = "Välj mappen där Spara (⌘S) lägger dina skärmdumpar"
        panel.directoryURL = saveFolderURL
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saveFolderPath = url.path
        return url
    }

    private func writeImage(to url: URL) {
        guard let rendered = ImageExporter.render(image: image, elements: elements),
              let data = exportFormat == .png ? rendered.pngData()
                                              : rendered.jpegData(compressionQuality: 0.92) else { return }
        do {
            try data.write(to: url)
            lastSavedURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if lastSavedURL == url { lastSavedURL = nil }
            }
        } catch {
            let a = NSAlert(); a.messageText = "Kunde inte spara"
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    private func copyToClipboard() -> Bool {
        guard let rendered = ImageExporter.render(image: image, elements: elements),
              let data = rendered.pngData() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        return true
    }

    private func copyAndCloseWindow() {
        guard copyToClipboard() else { return }
        NSApp.keyWindow?.performClose(nil)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(selectedTool.label)
                .font(.caption).foregroundStyle(.secondary)
            if selectedTool == .select, let id = selectedElementID,
               let el = elements.first(where: { $0.id == id }) {
                Text("· \(el.tool.label) markerad — Delete för att ta bort")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = lastSavedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Sparad: \(url.lastPathComponent) — visa i Finder", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.green)
            }
            Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - NSImage export helpers

extension NSImage {
    func jpegData(compressionQuality: CGFloat = 0.9) -> Data? {
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = self.size
            return rep.representation(using: .jpeg,
                                      properties: [.compressionFactor: compressionQuality])
        }
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        // Use the CGImage for full physical-pixel resolution.
        // Setting rep.size to the logical NSImage size encodes the correct DPI (e.g. 144 for 2x Retina)
        // so that Preview and other apps display it at the right size rather than treating it as 1x.
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = self.size   // logical pt size → DPI = pixelWidth / ptWidth * 72
            return rep.representation(using: .png, properties: [:])
        }
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
