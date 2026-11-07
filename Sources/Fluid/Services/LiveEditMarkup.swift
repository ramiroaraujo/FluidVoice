import AppKit

/// Hold to Capture Screenshot's arrows, brush strokes and squares, drawn over the box on screen and into the saved PNG.
nonisolated enum LiveEditMarkup {
    enum Tool { case arrow, brush, rectangle }

    struct Mark {
        var tool: Tool
        var color: NSColor = .systemRed
        /// Box-local points with a bottom-left origin; an arrow runs from the first to the last, and a square spans them.
        var points: [CGPoint]
    }

    private static let lineWidth: CGFloat = 4

    /// Draws the marks into the current graphics context, in box-local points.
    static func draw(_ marks: [Mark]) {
        for mark in marks {
            mark.color.set()
            let (line, head) = self.paths(for: mark)
            line.stroke()
            head?.fill()
            head?.stroke()
        }
    }

    /// The screenshot with its marks at the screenshot's pixel size; `size` is the box in points.
    static func png(_ screenshot: CGImage, size: CGSize, marks: [Mark]) -> Data? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = screenshot.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let context = CGContext(data: nil, width: screenshot.width, height: screenshot.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(screenshot, in: CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
        context.scaleBy(x: CGFloat(screenshot.width) / size.width, y: CGFloat(screenshot.height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        self.draw(marks)
        NSGraphicsContext.restoreGraphicsState()
        guard let marked = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: marked).representation(using: .png, properties: [:])
    }

    /// The stroked line, and for an arrow its filled head.
    private static func paths(for mark: Mark) -> (line: NSBezierPath, head: NSBezierPath?) {
        let line = NSBezierPath()
        line.lineWidth = self.lineWidth
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        guard let first = mark.points.first, let last = mark.points.last else { return (line, nil) }
        switch mark.tool {
        case .brush:
            line.move(to: first)
            // A single point still leaves a dot.
            (mark.points.count == 1 ? [first] : mark.points.dropFirst()).forEach(line.line(to:))
            return (line, nil)
        case .rectangle:
            line.appendRect(NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
            return (line, nil)
        case .arrow:
            let length = hypot(last.x - first.x, last.y - first.y)
            guard length > 0 else { return (line, nil) }
            let (dx, dy) = ((last.x - first.x) / length, (last.y - first.y) / length)
            let headLength = min(self.lineWidth * 5, length * 0.6)
            let base = CGPoint(x: last.x - dx * headLength, y: last.y - dy * headLength)
            // The shaft stops inside the head, so its round cap doesn't show past the tip.
            line.move(to: first)
            line.line(to: CGPoint(x: base.x + dx * 2, y: base.y + dy * 2))
            let head = NSBezierPath()
            head.lineWidth = 2
            head.lineJoinStyle = .round
            head.move(to: last)
            head.line(to: CGPoint(x: base.x - dy * headLength / 2, y: base.y + dx * headLength / 2))
            head.line(to: CGPoint(x: base.x + dy * headLength / 2, y: base.y - dx * headLength / 2))
            head.close()
            return (line, head)
        }
    }
}
