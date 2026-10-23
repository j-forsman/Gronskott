import SwiftUI

// Shared color palette
let paletteColors: [Color] = [
    .red, .orange, .yellow, .green, .blue, .purple, .white, .black
]

// MARK: - Tools

enum DrawingTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, roundedRect, ellipse, pen, speechBubble, highlight, text, blur, counter, crop

    var id: Self { self }

    var label: String {
        switch self {
        case .select:       return "Välj"
        case .arrow:        return "Pil"
        case .line:         return "Linje"
        case .rect:         return "Rektangel"
        case .roundedRect:  return "Rundad ruta"
        case .ellipse:      return "Ellips"
        case .pen:          return "Penna"
        case .speechBubble: return "Pratbubbla"
        case .highlight:    return "Markera"
        case .text:         return "Text"
        case .blur:         return "Sudda"
        case .counter:      return "Steg"
        case .crop:         return "Beskär"
        }
    }

    var icon: String {
        switch self {
        case .select:       return "cursorarrow"
        case .arrow:        return "arrow.up.right"
        case .line:         return "line.diagonal"
        case .rect:         return "rectangle"
        case .roundedRect:  return "app"
        case .ellipse:      return "oval"
        case .pen:          return "scribble"
        case .speechBubble: return "bubble.left"
        case .highlight:    return "highlighter"
        case .text:         return "textformat"
        case .blur:         return "aqi.medium"
        case .counter:      return "1.circle"
        case .crop:         return "crop"
        }
    }

    // Greenshot keyboard shortcuts
    var shortcut: KeyEquivalent? {
        switch self {
        case .select:       return .escape
        case .arrow:        return "a"
        case .line:         return "l"
        case .rect:         return "r"
        case .roundedRect:  return "g"
        case .ellipse:      return "e"
        case .pen:          return "f"
        case .speechBubble: return "b"
        case .highlight:    return "h"
        case .text:         return "t"
        case .blur:         return "o"
        case .counter:      return "n"
        case .crop:         return "c"
        }
    }

    var isShapeWithFill: Bool {
        self == .rect || self == .roundedRect || self == .ellipse || self == .speechBubble
    }
}

// MARK: - Modes

enum HighlightMode: String, CaseIterable, Identifiable {
    case text   // semi-transparent color over region
    case area   // darken everything outside

    var id: Self { self }
    var label: String {
        switch self {
        case .text: return "Markera text"
        case .area: return "Markera område"
        }
    }
}

enum BlurMode: String, CaseIterable, Identifiable {
    case pixelate
    case blur
    case redact     // solid black: the only mode that can't be reversed or read through

    var id: Self { self }
    var label: String {
        switch self {
        case .pixelate: return "Pixelera"
        case .blur:     return "Suddighet"
        case .redact:   return "Svart ruta"
        }
    }
}

// MARK: - Element

struct DrawingElement: Identifiable {
    let id = UUID()
    var tool: DrawingTool
    var start: CGPoint          // image-pixel coords, y=0 at top
    var end: CGPoint
    var colorIndex: Int
    var customColor: Color? = nil   // non-nil when user picked a custom color
    var strokeWidth: CGFloat
    var points: [CGPoint] = []  // freehand pen
    var text: String = ""
    var counter: Int = 1
    var isFilled: Bool = false
    var hasShadow: Bool = false
    var highlightMode: HighlightMode = .text
    var blurMode: BlurMode = .pixelate
    var opacity: CGFloat = 1.0

    var effectiveColor: Color {
        customColor ?? (colorIndex < paletteColors.count ? paletteColors[colorIndex] : .red)
    }
}

// MARK: - Hit testing & movement

extension DrawingElement {
    func hitTest(_ point: CGPoint) -> Bool {
        let tol: CGFloat = 10
        switch tool {
        case .select, .crop:
            return false
        case .rect, .roundedRect, .ellipse, .highlight, .blur, .speechBubble:
            return boundingRect.insetBy(dx: -tol, dy: -tol).contains(point)
        case .arrow, .line:
            return segmentDistance(point, a: start, b: end) < tol
        case .pen:
            guard points.count > 1 else { return false }
            return zip(points, points.dropFirst()).contains {
                segmentDistance(point, a: $0.0, b: $0.1) < tol
            }
        case .text:
            let r = textBox ?? CGRect(x: start.x, y: start.y, width: 250, height: 60)
            return r.insetBy(dx: -tol, dy: -tol).contains(point)
        case .counter:
            let r = max(18, strokeWidth * 5)
            return hypot(point.x - start.x, point.y - start.y) <= r + tol
        }
    }

    var boundingRect: CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    var fontSize: CGFloat { max(16, strokeWidth * 5) }

    // Where text wraps: a dragged text box, or the inside of a speech bubble.
    // nil = point text that grows from `start`.
    var textBox: CGRect? {
        switch tool {
        case .text:
            let r = boundingRect
            return r.width > 10 && r.height > 10 ? r : nil
        case .speechBubble:
            let pad = max(6, strokeWidth * 2)
            return boundingRect.insetBy(dx: pad, dy: pad)
        default:
            return nil
        }
    }

    // Text on a filled bubble must contrast with the fill.
    var textColor: Color {
        guard tool == .speechBubble, isFilled,
              let c = NSColor(effectiveColor).usingColorSpace(.sRGB) else { return effectiveColor }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? .black : .white
    }

    mutating func move(by delta: CGPoint) {
        start = start + delta
        end   = end   + delta
        points = points.map { $0 + delta }
    }

    var supportsResize: Bool {
        switch tool {
        case .text: return textBox != nil
        case .counter, .select, .crop: return false
        default: return true
        }
    }

    // handleIdx matches cropCorners order: 0=topLeft, 1=topRight, 2=bottomLeft, 3=bottomRight
    mutating func resize(handleIdx: Int, movingTo newPt: CGPoint) {
        let br = boundingRect
        let fixed: CGPoint
        switch handleIdx {
        case 0: fixed = CGPoint(x: br.maxX, y: br.maxY)   // topLeft → fix bottomRight
        case 1: fixed = CGPoint(x: br.minX, y: br.maxY)   // topRight → fix bottomLeft
        case 2: fixed = CGPoint(x: br.maxX, y: br.minY)   // bottomLeft → fix topRight
        case 3: fixed = CGPoint(x: br.minX, y: br.minY)   // bottomRight → fix topLeft
        default: return
        }

        let newMinX = min(fixed.x, newPt.x), newMaxX = max(fixed.x, newPt.x)
        let newMinY = min(fixed.y, newPt.y), newMaxY = max(fixed.y, newPt.y)

        let os = start, oe = end
        start.x = os.x <= oe.x ? newMinX : newMaxX
        end.x   = os.x <= oe.x ? newMaxX : newMinX
        start.y = os.y <= oe.y ? newMinY : newMaxY
        end.y   = os.y <= oe.y ? newMaxY : newMinY

        if !points.isEmpty, br.width > 0, br.height > 0 {
            let sx = (newMaxX - newMinX) / br.width, sy = (newMaxY - newMinY) / br.height
            points = points.map {
                CGPoint(x: ($0.x - br.minX) * sx + newMinX,
                        y: ($0.y - br.minY) * sy + newMinY)
            }
        }
    }

    func duplicated() -> DrawingElement {
        DrawingElement(
            tool: tool, start: start, end: end,
            colorIndex: colorIndex, customColor: customColor,
            strokeWidth: strokeWidth, points: points, text: text,
            counter: counter, isFilled: isFilled, hasShadow: hasShadow,
            highlightMode: highlightMode, blurMode: blurMode, opacity: opacity
        )
    }

    private func segmentDistance(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx*dx + dy*dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x)*dx + (p.y - a.y)*dy) / lenSq))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }
}

// MARK: - Image effects

enum ImageEffect: String, CaseIterable {
    case grayscale, invert, border, dropShadow, tornEdge

    var label: String {
        switch self {
        case .grayscale:  return "Gråskala"
        case .invert:     return "Invertera färger"
        case .border:     return "Lägg till ram"
        case .dropShadow: return "Droppskugga"
        case .tornEdge:   return "Avrivet kant"
        }
    }

    var icon: String {
        switch self {
        case .grayscale:  return "circle.lefthalf.filled"
        case .invert:     return "circle.filled.and.circle.righthalf.filled"
        case .border:     return "square"
        case .dropShadow: return "shadow"
        case .tornEdge:   return "scissors"
        }
    }
}

// MARK: - CGPoint arithmetic

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
}
