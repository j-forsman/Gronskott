import AppKit
import CoreImage
import CoreText
import SwiftUI

enum ImageExporter {

    // MARK: - Main render

    static func render(image: NSImage, elements: [DrawingElement]) -> NSImage? {
        guard let srcCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let logW = image.size.width, logH = image.size.height
        guard logW > 0, logH > 0 else { return nil }

        let physW = srcCG.width, physH = srcCG.height

        // NSBitmapImageRep at physical pixel size, logical point size (encodes correct DPI for PNG export)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: physW, pixelsHigh: physH,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: logW, height: logH)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext

        // NSGraphicsContext(bitmapImageRep:) uses pixel coordinates by default.
        // Scale to logical point space so all drawing code works in (logW × logH) units.
        ctx.scaleBy(x: CGFloat(physW) / logW, y: CGFloat(physH) / logH)

        // Draw base image via AppKit — handles y-up orientation and color correctly
        image.draw(in: NSRect(x: 0, y: 0, width: logW, height: logH))

        for el in elements {
            let cgColor = NSColor(el.effectiveColor).cgColor

            switch el.tool {
            case .select, .crop:
                break

            case .blur:
                ctx.saveGState()
                ctx.setAlpha(el.opacity)
                renderBlur(el, ctx: ctx, source: srcCG, imgSize: CGSize(width: logW, height: logH))
                ctx.restoreGState()

            case .highlight where el.highlightMode == .area:
                ctx.saveGState()
                ctx.setAlpha(el.opacity)
                renderHighlightArea(el, ctx: ctx, imgSize: CGSize(width: logW, height: logH))
                ctx.restoreGState()

            default:
                ctx.saveGState()
                ctx.setAlpha(el.opacity)
                if el.hasShadow {
                    ctx.setShadow(offset: CGSize(width: 3, height: -3), blur: 6,
                                  color: makeCGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
                }
                renderElement(el, ctx: ctx, cgColor: cgColor, imgH: logH)
                ctx.restoreGState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: logW, height: logH))
        result.addRepresentation(rep)
        return result
    }

    // MARK: - Element rendering (y-up AppKit context)

    private static func renderElement(_ el: DrawingElement,
                                      ctx: CGContext, cgColor: CGColor, imgH: CGFloat) {
        ctx.setStrokeColor(cgColor)
        ctx.setFillColor(cgColor)
        ctx.setLineWidth(el.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch el.tool {
        case .arrow:        drawArrow(el, ctx: ctx, imgH: imgH)
        case .line:         drawLine(el, ctx: ctx, imgH: imgH)
        case .rect:         drawRect(el, ctx: ctx, imgH: imgH)
        case .roundedRect:  drawRoundedRect(el, ctx: ctx, imgH: imgH)
        case .ellipse:      drawEllipse(el, ctx: ctx, imgH: imgH)
        case .pen:          drawPen(el, ctx: ctx, imgH: imgH)
        case .speechBubble: drawSpeechBubble(el, ctx: ctx, cgColor: cgColor, imgH: imgH)
        case .highlight:    drawHighlight(el, ctx: ctx, cgColor: cgColor, imgH: imgH)
        case .text:         drawText(el, ctx: ctx, imgH: imgH)
        case .counter:      drawCounter(el, ctx: ctx, cgColor: cgColor, imgH: imgH)
        case .select, .crop, .blur: break
        }
    }

    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Flip SwiftUI y-down → AppKit y-up
    private static func fy(_ y: CGFloat, h: CGFloat) -> CGFloat { h - y }
    private static func fp(_ p: CGPoint, h: CGFloat) -> CGPoint { CGPoint(x: p.x, y: fy(p.y, h: h)) }

    private static func exportRect(_ el: DrawingElement, imgH: CGFloat) -> CGRect {
        let maxY = max(el.start.y, el.end.y)
        return CGRect(
            x: min(el.start.x, el.end.x), y: fy(maxY, h: imgH),
            width: abs(el.end.x - el.start.x), height: abs(el.end.y - el.start.y)
        )
    }

    private static func drawArrow(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        guard el.start != el.end else { return }
        let s = fp(el.start, h: imgH), e = fp(el.end, h: imgH)
        ctx.beginPath()
        ctx.move(to: s); ctx.addLine(to: e)
        let angle = atan2(e.y - s.y, e.x - s.x)
        let head = max(14, el.strokeWidth * 4.5)
        let sp: CGFloat = .pi / 6
        ctx.move(to: e)
        ctx.addLine(to: CGPoint(x: e.x - head * cos(angle - sp), y: e.y - head * sin(angle - sp)))
        ctx.move(to: e)
        ctx.addLine(to: CGPoint(x: e.x - head * cos(angle + sp), y: e.y - head * sin(angle + sp)))
        ctx.strokePath()
    }

    private static func drawLine(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        ctx.beginPath()
        ctx.move(to: fp(el.start, h: imgH)); ctx.addLine(to: fp(el.end, h: imgH))
        ctx.strokePath()
    }

    private static func drawRect(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        let r = exportRect(el, imgH: imgH)
        if el.isFilled { ctx.fill(r) } else { ctx.stroke(r) }
    }

    private static func drawRoundedRect(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        let r = exportRect(el, imgH: imgH)
        let cr = min(r.width, r.height) * 0.18
        let path = CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil)
        if el.isFilled { ctx.addPath(path); ctx.fillPath() }
        else            { ctx.addPath(path); ctx.strokePath() }
    }

    private static func drawEllipse(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        let r = exportRect(el, imgH: imgH)
        if el.isFilled { ctx.fillEllipse(in: r) } else { ctx.strokeEllipse(in: r) }
    }

    private static func drawPen(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        guard el.points.count > 1 else { return }
        ctx.beginPath()
        ctx.move(to: fp(el.points[0], h: imgH))
        el.points.dropFirst().forEach { ctx.addLine(to: fp($0, h: imgH)) }
        ctx.strokePath()
    }

    private static func drawSpeechBubble(_ el: DrawingElement, ctx: CGContext,
                                         cgColor: CGColor, imgH: CGFloat) {
        let r = exportRect(el, imgH: imgH)
        guard r.width > 4, r.height > 4 else { return }
        let cr: CGFloat = min(r.width, r.height) * 0.15
        let path = CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil)

        let tw: CGFloat = max(12, r.width * 0.18)
        let th: CGFloat = max(14, r.height * 0.28)
        let cx = r.midX
        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: cx - tw/2, y: r.minY))
        tailPath.addLine(to: CGPoint(x: cx, y: r.minY - th))
        tailPath.addLine(to: CGPoint(x: cx + tw/2, y: r.minY))
        tailPath.closeSubpath()

        if el.isFilled {
            ctx.addPath(path); ctx.fillPath()
            ctx.addPath(tailPath); ctx.fillPath()
        } else {
            ctx.addPath(path); ctx.strokePath()
            ctx.addPath(tailPath); ctx.strokePath()
        }
        drawText(el, ctx: ctx, imgH: imgH)
    }

    private static func drawHighlight(_ el: DrawingElement, ctx: CGContext,
                                      cgColor: CGColor, imgH: CGFloat) {
        ctx.setFillColor(cgColor.copy(alpha: 0.38) ?? cgColor)
        ctx.fill(exportRect(el, imgH: imgH))
    }

    private static func renderHighlightArea(_ el: DrawingElement, ctx: CGContext,
                                            imgSize: CGSize) {
        // Darken everything outside the rect (AppKit y-up coords)
        let r = exportRect(el, imgH: imgSize.height)
        let full = CGRect(origin: .zero, size: imgSize)
        ctx.saveGState()
        ctx.setFillColor(makeCGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        // Even-odd fill: full rect minus hole (the highlighted area)
        ctx.beginPath()
        ctx.addRect(full)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // Mirrors EditorView.renderText: wrap inside textBox, bubbles centre the block,
    // point text grows right/down from `start`.
    private static func drawText(_ el: DrawingElement, ctx: CGContext, imgH: CGFloat) {
        guard !el.text.isEmpty else { return }
        let attrStr = NSAttributedString(string: el.text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: el.fontSize),
            .foregroundColor: NSColor(el.textColor)
        ])
        let setter = CTFramesetterCreateWithAttributedString(attrStr)
        let big: CGFloat = 100_000
        let box = el.textBox ?? CGRect(x: el.start.x, y: el.start.y, width: big, height: big)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
        // Text block in y-down image coords, then flipped once into AppKit space
        var block = CGRect(x: box.minX, y: box.minY, width: box.width, height: min(fit.height, box.height))
        if el.tool == .speechBubble {
            block.origin = CGPoint(x: box.midX - fit.width / 2, y: box.midY - block.height / 2)
            block.size.width = ceil(fit.width) + 1
        }
        let r = CGRect(x: block.minX, y: fy(block.maxY, h: imgH), width: block.width, height: block.height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: r, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private static func drawCounter(_ el: DrawingElement, ctx: CGContext,
                                    cgColor: CGColor, imgH: CGFloat) {
        let center = fp(el.start, h: imgH)
        let r = max(15, el.strokeWidth * 4)
        let circ = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        ctx.setFillColor(cgColor); ctx.fillEllipse(in: circ)
        ctx.setStrokeColor(makeCGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.setLineWidth(1.5); ctx.strokeEllipse(in: circ)

        let isLight = el.colorIndex == 6
        let textCG: CGColor = isLight ? .init(red: 0, green: 0, blue: 0, alpha: 1)
                                      : .init(red: 1, green: 1, blue: 1, alpha: 1)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, r * 0.95, nil)
        let attrStr = NSAttributedString(string: String(el.counter), attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: textCG) ?? .white
        ])
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Blur / Pixelate

    private static func renderBlur(_ el: DrawingElement, ctx: CGContext,
                                   source: CGImage, imgSize: CGSize) {
        let swiftRect = el.boundingRect
        guard swiftRect.width > 4, swiftRect.height > 4 else { return }

        if el.blurMode == .redact {
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: swiftRect.minX, y: fy(swiftRect.maxY, h: imgSize.height),
                            width: swiftRect.width, height: swiftRect.height))
            return
        }

        let pxScaleX = CGFloat(source.width)  / imgSize.width
        let pxScaleY = CGFloat(source.height) / imgSize.height
        let srcBounds = CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height))

        let basePxCrop = CGRect(
            x: swiftRect.minX * pxScaleX,
            y: swiftRect.minY * pxScaleY,
            width:  swiftRect.width  * pxScaleX,
            height: swiftRect.height * pxScaleY
        )

        if el.blurMode == .blur {
            let blurRadius = 7.0 * pxScaleX
            // Expand the source crop so CIGaussianBlur samples real pixels at all edges
            // instead of fading to transparent — this prevents the soft-edge artifact.
            let expandedPxCrop = basePxCrop.insetBy(dx: -blurRadius * 3, dy: -blurRadius * 3)
                                           .intersection(srcBounds)
            guard let cropped = source.cropping(to: expandedPxCrop) else { return }
            let ciSrc = CIImage(cgImage: cropped)
            let filtered = ciSrc.applyingFilter("CIGaussianBlur",
                                                parameters: [kCIInputRadiusKey: blurRadius])
                                .cropped(to: ciSrc.extent)
            guard let cgResult = ciContext.createCGImage(filtered, from: ciSrc.extent) else { return }

            // Clip to the original blur rect and draw the expanded result positioned behind it
            let dest = CGRect(x: swiftRect.minX, y: fy(swiftRect.maxY, h: imgSize.height),
                              width: swiftRect.width, height: swiftRect.height)
            let expandedSwift = CGRect(
                x: expandedPxCrop.minX / pxScaleX, y: expandedPxCrop.minY / pxScaleY,
                width: expandedPxCrop.width / pxScaleX, height: expandedPxCrop.height / pxScaleY
            )
            let expandedDest = CGRect(
                x: expandedSwift.minX, y: fy(expandedSwift.maxY, h: imgSize.height),
                width: expandedSwift.width, height: expandedSwift.height
            )
            ctx.saveGState()
            ctx.clip(to: dest)
            ctx.translateBy(x: expandedDest.minX, y: expandedDest.minY + expandedDest.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgResult, in: CGRect(x: 0, y: 0, width: expandedDest.width, height: expandedDest.height))
            ctx.restoreGState()
        } else {
            guard let cropped = source.cropping(to: basePxCrop) else { return }
            let ciSrc = CIImage(cgImage: cropped)
            // Align pixel grid from the corner of the region for consistent block edges
            let filtered = ciSrc.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(4.0, 10.0 * pxScaleX),
                kCIInputCenterKey: CIVector(x: ciSrc.extent.minX, y: ciSrc.extent.minY)
            ])
            guard let cgResult = ciContext.createCGImage(filtered, from: ciSrc.extent) else { return }

            let dest = CGRect(x: swiftRect.minX, y: fy(swiftRect.maxY, h: imgSize.height),
                              width: swiftRect.width, height: swiftRect.height)
            ctx.saveGState()
            ctx.translateBy(x: dest.minX, y: dest.minY + dest.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgResult, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
            ctx.restoreGState()
        }
    }

    // MARK: - Image Effects

    static func applyEffect(_ effect: ImageEffect, to image: NSImage) -> NSImage? {
        switch effect {
        case .grayscale:
            return applyCIFilter("CIColorMonochrome",
                                 params: ["inputColor": CIColor.gray, "inputIntensity": 1.0],
                                 to: image)
        case .invert:
            return applyCIFilter("CIColorInvert", params: [:], to: image)
        case .border:
            return applyBorder(to: image, width: 10, color: .black)
        case .dropShadow:
            return applyDropShadow(to: image)
        case .tornEdge:
            return applyTornEdge(to: image)
        }
    }

    private static func applyCIFilter(_ name: String, params: [String: Any],
                                      to image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg).applyingFilter(name, parameters: params)
        guard let result = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }

    private static func applyBorder(to image: NSImage, width: CGFloat, color: NSColor) -> NSImage? {
        let nw = image.size.width + width * 2, nh = image.size.height + width * 2
        let result = NSImage(size: NSSize(width: nw, height: nh))
        result.lockFocus(); defer { result.unlockFocus() }
        color.setFill()
        NSRect(x: 0, y: 0, width: nw, height: nh).fill()
        image.draw(in: NSRect(x: width, y: width, width: image.size.width, height: image.size.height))
        return result
    }

    private static func applyDropShadow(to image: NSImage) -> NSImage? {
        let pad: CGFloat = 24
        let nw = image.size.width + pad * 2, nh = image.size.height + pad * 2
        let result = NSImage(size: NSSize(width: nw, height: nh))
        result.lockFocus(); defer { result.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        ctx.setShadow(offset: CGSize(width: 5, height: -5), blur: 14,
                      color: makeCGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        image.draw(in: NSRect(x: pad, y: pad, width: image.size.width, height: image.size.height))
        return result
    }

    private static func applyTornEdge(to image: NSImage) -> NSImage? {
        let W = image.size.width, H = image.size.height
        let result = NSImage(size: NSSize(width: W, height: H))
        result.lockFocus(); defer { result.unlockFocus() }
        let amp: CGFloat = 8, segs = 30
        let path = NSBezierPath()
        path.move(to: .zero)
        for i in 0...segs {
            path.line(to: NSPoint(x: W * CGFloat(i) / CGFloat(segs),
                                  y: amp * CGFloat.random(in: -1...1)))
        }
        for i in 0...segs {
            path.line(to: NSPoint(x: W + amp * CGFloat.random(in: -1...1),
                                  y: H * CGFloat(i) / CGFloat(segs)))
        }
        for i in 0...segs {
            path.line(to: NSPoint(x: W - W * CGFloat(i) / CGFloat(segs),
                                  y: H + amp * CGFloat.random(in: -1...1)))
        }
        for i in 0...segs {
            path.line(to: NSPoint(x: amp * CGFloat.random(in: -1...1),
                                  y: H - H * CGFloat(i) / CGFloat(segs)))
        }
        path.close(); path.addClip()
        image.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
        return result
    }
}

// MARK: - CGColor helpers

private func makeCGColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}
