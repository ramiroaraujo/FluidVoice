import AppKit
import ScreenCaptureKit
import SwiftUI

/// Hold to Capture Screenshot: while dictating, holding Right Option and Right Shift together, and nothing
/// else, turns the pointer into the screenshot crosshair on every screen. Dragging a box captures it, and while
/// the keys stay held the box takes arrows, brush strokes and squares. Letting go appends the marked-up screenshot
/// to the transcript as an `[image N]` placeholder. Our own overlay, because macOS's screenshot tool
/// resizes from the center while Option is held.
@MainActor
final class LiveEditScreenshot {
    static let shared = LiveEditScreenshot()

    /// Right Option and Right Shift.
    static let keyCodes: Set<UInt16> = [61, 60]

    /// Reads the physical keys; key state reports right-hand modifiers under the left keys' codes, so the
    /// device flags tell the sides apart.
    static var keysHeld: Bool {
        let mask = UInt64(NX_DEVICERALTKEYMASK | NX_DEVICERSHIFTKEYMASK)
        return CGEventSource.flagsState(.hidSystemState).rawValue & mask == mask
    }

    /// The cursor macOS shows for ⌘⇧4, redrawn from measurements of screencapture's own: a black cross
    /// with a faint white edge and a light ring, and two numbers beside it, below the cross or above it
    /// near the bottom of the screen.
    static func cursor(numbers: (CGFloat, CGFloat)?, above: Bool) -> NSCursor {
        let lines = numbers.map { [$0.0, $0.1].map { self.numberFormatter.string(from: NSNumber(value: Double($0))) ?? "" } }
        let key = "\(lines ?? [])\(above)"
        if let cached = self.cachedCursor, cached.key == key { return cached.cursor }
        let crossY: CGFloat = above && lines != nil ? 23 : 15
        let image = NSImage(size: NSSize(width: 64, height: 40), flipped: true) { _ in
            let center = NSPoint(x: 15.5, y: crossY + 0.5)
            func bars(_ halfLength: CGFloat, _ halfWidth: CGFloat) -> [NSRect] {
                [NSRect(x: center.x - halfLength, y: center.y - halfWidth, width: halfLength * 2, height: halfWidth * 2),
                 NSRect(x: center.x - halfWidth, y: center.y - halfLength, width: halfWidth * 2, height: halfLength * 2)]
            }
            let edge = NSBezierPath()
            bars(12.5, 1.5).forEach(edge.appendRect)
            NSColor(white: 1, alpha: 0.19).setFill()
            edge.fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 6.1, y: center.y - 6.1, width: 12.2, height: 12.2))
            NSColor(white: 0.25, alpha: 0.16).setFill()
            ring.fill()
            ring.lineWidth = 1
            NSColor(white: 0.36, alpha: 0.49).setStroke()
            ring.stroke()
            // The black replaces the edge and ring under it, and leaves the hotspot open.
            NSColor(white: 0, alpha: 0.75).setFill()
            for bar in bars(11.5, 0.5) {
                let edge: CGRectEdge = bar.width > bar.height ? .minXEdge : .minYEdge
                let (before, rest) = bar.divided(atDistance: 11, from: edge)
                before.fill(using: .copy)
                rest.divided(atDistance: 1, from: edge).remainder.fill(using: .copy)
            }
            guard let lines else { return true }
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 1, alpha: 0.9)
            shadow.shadowOffset = NSSize(width: 0.75, height: -0.75)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black, .shadow: shadow]
            for (index, line) in lines.enumerated() {
                NSAttributedString(string: line, attributes: attributes).draw(at: NSPoint(x: 22, y: (above ? 1 : 16.5) + CGFloat(index) * 9.5))
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 15, y: crossY))
        self.cachedCursor = (key, cursor)
        return cursor
    }

    private static var cachedCursor: (key: String, cursor: NSCursor)?

    /// The brush tool's pointer inside the box: a pencil, black with a white outline like the system
    /// pointers so it shows on light and dark screenshots, with its tip on the line.
    static let pencilCursor: NSCursor = {
        guard let symbol = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil) else { return .crosshair }
        func tinted(_ color: NSColor) -> NSImage {
            symbol.withSymbolConfiguration(.init(pointSize: 16, weight: .regular).applying(.init(paletteColors: [color]))) ?? symbol
        }
        let (outline, fill) = (tinted(.white), tinted(.black))
        let image = NSImage(size: NSSize(width: fill.size.width + 2, height: fill.size.height + 2), flipped: true) { _ in
            for dx: CGFloat in [0, 1, 2] {
                for dy: CGFloat in [0, 1, 2] where dx != 1 || dy != 1 {
                    outline.draw(in: NSRect(origin: NSPoint(x: dx, y: dy), size: outline.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            fill.draw(in: NSRect(origin: NSPoint(x: 1, y: 1), size: fill.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 14))
    }()

    /// Whole points with the locale's grouping, like screencapture's "1.301".
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .down
        return formatter
    }()

    private var views: [SelectionView] = []
    private var isDragging = false
    /// The box being marked up and its screenshot, taken when the box was drawn.
    private var shot: (view: SelectionView, image: Task<CGImage?, Never>)?

    private init() {}

    var isShowing: Bool { !self.views.isEmpty }

    func begin() {
        guard self.views.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            DebugLogger.shared.warning("Hold to Capture Screenshot needs Screen Recording permission", source: "LiveEdit")
            CGRequestScreenCaptureAccess()
            return
        }
        Self.setsCursorInBackground(true)
        self.views = NSScreen.screens.map(self.makeView(on:))
        self.views.forEach { $0.window?.orderFrontRegardless() }
        // A key panel makes FluidVoice active without bringing it forward, so the toolbar takes clicks.
        // Ordering the panels out hands typing back to the target app.
        let mouse = NSEvent.mouseLocation
        let view = self.views.first { $0.window?.frame.contains(mouse) == true } ?? self.views.first
        view?.window?.makeKey()
        view?.updateCursor()
    }

    /// The key went up or another modifier joined it: the marked-up box goes into the transcript.
    /// A drag in progress finishes first.
    func modifierReleased() {
        guard !self.views.isEmpty, !self.isDragging else { return }
        let shot = self.shot.flatMap { shot in
            shot.view.box.map { box in
                (image: shot.image, frame: shot.view.window?.convertToScreen(shot.view.convert(box, to: nil)) ?? box, marks: shot.view.marks)
            }
        }
        self.dismiss()
        guard let shot else { return }
        Task {
            guard let screenshot = await shot.image.value else { return }
            guard let png = LiveEditMarkup.png(screenshot, size: shot.frame.size, marks: shot.marks) else {
                DebugLogger.shared.error("Hold to Capture Screenshot could not encode the screenshot", source: "LiveEdit")
                return
            }
            do {
                LiveEditSession.shared.appendScreenshot(at: try LiveEditImagePaste.save(png))
                Self.flyToNotch(png, from: shot.frame)
            } catch {
                DebugLogger.shared.error("Hold to Capture Screenshot could not save the screenshot: \(error.localizedDescription)", source: "LiveEdit")
            }
        }
    }

    /// Esc: the overlay closes and nothing is attached.
    func cancel() {
        self.shot?.image.cancel()
        self.dismiss()
    }

    /// Shrinks the attached screenshot into the notch, where its `[image N]` lands.
    private static func flyToNotch(_ png: Data, from frame: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let image = NSImage(data: png),
              let screen = NotchOverlayManager.shared.presentationPolicyScreen ?? NSScreen.main
        else { return }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        panel.contentView = view
        panel.orderFrontRegardless()
        // The notch's text sits about 100pt below the top of its screen.
        let target = NSRect(x: screen.frame.midX - frame.width * 0.025, y: screen.frame.maxY - 100 - frame.height * 0.025,
                            width: frame.width * 0.05, height: frame.height * 0.05)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0.4
        } completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        }
    }

    private func dismiss() {
        self.isDragging = false
        self.shot = nil
        self.views.forEach { $0.window?.orderOut(nil) }
        self.views = []
        NSCursor.arrow.set()
        Self.setsCursorInBackground(false)
    }

    private func makeView(on screen: NSScreen) -> SelectionView {
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onDragStart = { [weak self] in self?.isDragging = true }
        view.onBoxStart = { [weak self, weak view] in
            guard let self else { return }
            self.shot?.image.cancel()
            self.shot = nil
            self.views.filter { $0 !== view }.forEach { $0.clear() }
        }
        view.onBoxDrawn = { [weak self, weak view] rect in
            guard let self, let view else { return }
            let image = Task { () -> CGImage? in
                let image = await Self.capture(rect, on: screen)
                if !Task.isCancelled { view.screenshot = image }
                return image
            }
            self.shot = (view, image)
        }
        view.onDragEnd = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            if !Self.keysHeld { self.modifierReleased() }
        }
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        return view
    }

    private static func capture(_ rect: NSRect, on screen: NSScreen) async -> CGImage? {
        do {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            // Leave FluidVoice's notch and this overlay out of the shot.
            let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            // Display-local points with a top-left origin.
            configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((rect.width * scale).rounded())
            configuration.height = Int((rect.height * scale).rounded())
            configuration.captureResolution = .best
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            DebugLogger.shared.error("Hold to Capture Screenshot failed: \(error.localizedDescription)", source: "LiveEdit")
            return nil
        }
    }

    /// Without this, macOS keeps the frontmost app's cursor over our panels: FluidVoice isn't frontmost
    /// while dictating. Private CoreGraphics property, the one screenshot tools use; looked up at run time.
    private static func setsCursorInBackground(_ enabled: Bool) {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(everywhere, "_CGSDefaultConnection"), let setProperty = dlsym(everywhere, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetConnectionProperty.self)(id, id, "SetsCursorInBackground" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// AppKit resets the cursor to the arrow while routing enter and exit events, so the crosshair
    /// goes back on after every event.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        (self.contentView as? SelectionView)?.updateCursor()
    }
}

/// One screen's overlay: dims the screen outside the box, labels the box with its size, and once a box
/// is drawn shows its screenshot under the marks, with the markup bar under it.
private final class SelectionView: NSView {
    static let colors: [NSColor] = [.systemRed, .systemYellow, .systemBlue, .white]
    /// Kept between captures; the tool starts on the brush each time.
    private static var color = NSColor.systemRed
    private var tool = LiveEditMarkup.Tool.brush

    var onDragStart: (() -> Void)?
    /// A new box replaces any box on any screen.
    var onBoxStart: (() -> Void)?
    /// The box in screen coordinates.
    var onBoxDrawn: ((NSRect) -> Void)?
    var onDragEnd: (() -> Void)?

    private(set) var box: NSRect?
    private(set) var marks: [LiveEditMarkup.Mark] = []
    var screenshot: CGImage? { didSet { self.needsDisplay = true } }
    private var drag: (start: NSPoint, current: NSPoint)?
    private lazy var bar = NSHostingView(rootView: self.makeBar())

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.bar.isHidden = true
        self.addSubview(self.bar)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func clear() {
        self.box = nil
        self.marks = []
        self.screenshot = nil
        self.bar.isHidden = true
        self.needsDisplay = true
    }

    /// Like ⌘⇧4, the numbers are the pointer's position from the screen's top left, or the box's size
    /// while it's dragged. Drawing inside a box shows the plain cross, or a pencil for the brush.
    func updateCursor() {
        guard let window else { return }
        let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !self.bar.isHidden, self.bar.frame.contains(point) { return NSCursor.arrow.set() }
        if self.tool == .brush, self.drag == nil, self.box?.contains(point) == true { return LiveEditScreenshot.pencilCursor.set() }
        let numbers: (CGFloat, CGFloat)? = if let drag {
            (abs(drag.current.x - drag.start.x), abs(drag.current.y - drag.start.y))
        } else if self.box?.contains(point) == true {
            nil
        } else {
            (point.x, self.bounds.maxY - point.y)
        }
        // The numbers would hang off the bottom of the screen.
        LiveEditScreenshot.cursor(numbers: numbers, above: point.y < 25).set()
    }

    private func makeBar() -> MarkupBar {
        MarkupBar(
            tool: self.tool, color: Self.color, canUndo: !self.marks.isEmpty,
            pick: { [weak self] in self?.tool = $0; self?.refreshBar() },
            pickColor: { [weak self] in Self.color = $0; self?.refreshBar() },
            undo: { [weak self] in
                guard let self, !self.marks.isEmpty else { return }
                self.marks.removeLast()
                self.needsDisplay = true
                self.refreshBar()
            }
        )
    }

    private func refreshBar() {
        self.bar.rootView = self.makeBar()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.trackingAreas.forEach(self.removeTrackingArea)
        self.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    /// With several screens, the one under the pointer takes the key so its toolbar takes clicks.
    override func mouseEntered(with _: NSEvent) {
        self.window?.makeKey()
    }

    override func cursorUpdate(with _: NSEvent) {
        self.updateCursor()
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        self.onDragStart?()
        if let box, box.contains(point) {
            self.marks.append(.init(tool: self.tool, color: Self.color, points: [self.boxLocal(point, in: box)]))
        } else {
            self.clear()
            self.onBoxStart?()
            self.drag = (point, point)
        }
        self.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        if let drag {
            self.drag = (drag.start, point)
        } else if let box, !self.marks.isEmpty {
            self.marks[self.marks.count - 1].points.append(self.boxLocal(point, in: box))
        }
        self.needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        if let drag {
            self.drag = nil
            let rect = Self.rect(drag.start, drag.current)
            if rect.width >= 4, rect.height >= 4, let window {
                self.box = rect
                self.placeBar(beside: rect)
                self.onBoxDrawn?(window.convertToScreen(self.convert(rect, to: nil)))
            }
        } else if let mark = self.marks.last, mark.tool != .brush, let first = mark.points.first, let last = mark.points.last,
                  hypot(last.x - first.x, last.y - first.y) < 4 {
            // A click with the arrow or square tool draws nothing.
            self.marks.removeLast()
        }
        self.refreshBar()
        self.needsDisplay = true
        self.onDragEnd?()
    }

    override func draw(_: NSRect) {
        // Fully clear pixels would let clicks through to the apps below.
        NSColor.black.withAlphaComponent(0.38).setFill()
        self.bounds.fill()
        guard let rect = self.box ?? self.drag.map({ Self.rect($0.start, $0.current) }) else { return }
        NSColor.black.withAlphaComponent(0.01).setFill()
        rect.fill(using: .copy)
        if let screenshot, let context = NSGraphicsContext.current?.cgContext {
            context.draw(screenshot, in: rect)
        }
        // White on a dark hairline shows on light and dark content alike.
        NSColor.black.withAlphaComponent(0.55).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        self.drawSize(of: rect)
        guard self.box != nil else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let toBox = NSAffineTransform()
        toBox.translateX(by: rect.minX, yBy: rect.minY)
        toBox.concat()
        LiveEditMarkup.draw(self.marks)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The size in points on the box's top-left corner, inside the box when the menu bar is in the way.
    private func drawSize(of rect: NSRect) {
        let label = NSAttributedString(string: "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        var tag = NSRect(x: rect.minX, y: rect.maxY + 6, width: ceil(size.width) + 14, height: ceil(size.height) + 6)
        if tag.maxY > self.bounds.maxY - 36 { tag.origin = NSPoint(x: rect.minX + 6, y: rect.maxY - 6 - tag.height) }
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 6, yRadius: 6).fill()
        label.draw(at: NSPoint(x: tag.minX + 7, y: tag.minY + 3))
    }

    /// Centered under the box, or over it when the box reaches the bottom of the screen.
    private func placeBar(beside box: NSRect) {
        self.refreshBar()
        let size = self.bar.fittingSize
        var origin = NSPoint(x: box.midX - size.width / 2, y: box.minY - size.height - 12)
        if origin.y < self.bounds.minY + 8 { origin.y = min(box.maxY + 12, self.bounds.maxY - size.height - 8) }
        origin.x = min(max(origin.x, self.bounds.minX + 8), self.bounds.maxX - size.width - 8)
        self.bar.frame = NSRect(origin: origin, size: size)
        self.bar.isHidden = false
    }

    private func boxLocal(_ point: NSPoint, in box: NSRect) -> CGPoint {
        CGPoint(x: point.x - box.minX, y: point.y - box.minY)
    }

    private static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// The bar under a captured box: tools, colors, undo, and how to finish.
private struct MarkupBar: View {
    let tool: LiveEditMarkup.Tool
    let color: NSColor
    let canUndo: Bool
    /// The hold key's name, for the hint.
    let pick: (LiveEditMarkup.Tool) -> Void
    let pickColor: (NSColor) -> Void
    let undo: () -> Void

    private static let tools: [(tool: LiveEditMarkup.Tool, symbol: String, name: String)] = [
        (.arrow, "arrow.up.right", "Arrow"), (.brush, "scribble", "Brush"), (.rectangle, "square", "Square"),
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.tools, id: \.symbol) { item in
                Button { self.pick(item.tool) } label: {
                    Image(systemName: item.symbol)
                        .frame(width: 30, height: 28)
                        .foregroundStyle(item.tool == self.tool ? .white : .white.opacity(0.82))
                        .background(item.tool == self.tool ? Color.white.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .help(item.name)
            }
            self.separator
            ForEach(SelectionView.colors, id: \.self) { color in
                Button { self.pickColor(color) } label: {
                    Circle().fill(Color(nsColor: color)).frame(width: 14, height: 14)
                        .padding(3.5)
                        .overlay { if color == self.color { Circle().strokeBorder(.white, lineWidth: 1.5) } }
                        .contentShape(Rectangle())
                }
            }
            self.separator
            Button(action: self.undo) {
                Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .disabled(!self.canUndo)
            .opacity(self.canUndo ? 1 : 0.35)
            .help("Undo")
            Text("Let go of the keys to attach")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 6)
                .padding(.trailing, 4)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Color(white: 0.12, opacity: 0.9), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18).padding(.horizontal, 5)
    }
}
