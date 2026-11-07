import AppKit

@main
enum LiveEditMarkupTests {
    static func main() {
        // A white 20×10 point box captured at 2× pixel scale.
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let screenshot = context.makeImage()!
        let size = CGSize(width: 20, height: 10)

        func render(_ marks: [LiveEditMarkup.Mark]) -> NSBitmapImageRep {
            NSBitmapImageRep(data: LiveEditMarkup.png(screenshot, size: size, marks: marks)!)!
        }
        func isRed(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            return color.redComponent > 0.8 && color.greenComponent < 0.5
        }

        let unmarked = render([])
        precondition(unmarked.pixelsWide == 40 && unmarked.pixelsHigh == 20, "Keeps the screenshot's pixel size")
        precondition(!isRed(unmarked, 20, 10), "No marks leaves the screenshot as it was")

        let brush = render([.init(tool: .brush, points: [CGPoint(x: 2, y: 5), CGPoint(x: 10, y: 5), CGPoint(x: 18, y: 5)])])
        precondition(isRed(brush, 20, 10), "A brush stroke is drawn at the screenshot's scale")
        precondition(!isRed(brush, 20, 1) && !isRed(brush, 20, 18), "A brush stroke stays the brush's width")

        // Arrowhead arms are mirrored about the shaft, so these hold whichever way rows are counted.
        let arrow = render([.init(tool: .arrow, points: [CGPoint(x: 2, y: 5), CGPoint(x: 6, y: 1), CGPoint(x: 18, y: 5)])])
        precondition(isRed(arrow, 10, 10) && isRed(arrow, 30, 10), "An arrow is a straight shaft from its first point to its last")
        precondition(isRed(arrow, 26, 4) && isRed(arrow, 26, 16), "An arrow has a head at its last point")
        precondition(!isRed(arrow, 12, 2) && !isRed(arrow, 12, 18), "An arrow ignores the points in between")

        let square = render([.init(tool: .rectangle, points: [CGPoint(x: 4, y: 2), CGPoint(x: 10, y: 3), CGPoint(x: 16, y: 8)])])
        precondition(isRed(square, 8, 10) && isRed(square, 32, 10), "A square is outlined between its first and last points")
        precondition(!isRed(square, 20, 10), "A square is only an outline")

        let blue = render([.init(tool: .brush, color: .systemBlue, points: [CGPoint(x: 2, y: 5), CGPoint(x: 18, y: 5)])])
        let stroke = blue.colorAt(x: 20, y: 10)!.usingColorSpace(.sRGB)!
        precondition(stroke.blueComponent > 0.8 && stroke.redComponent < 0.5, "A mark keeps its color")

        print("Live Edit markup tests passed")
    }
}
