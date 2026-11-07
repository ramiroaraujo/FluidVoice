import AppKit
import ScreenCaptureKit

/// Hold to Capture Screenshot: while dictating, holding the configured key alone turns the pointer
/// into a selector on every screen. Dragging a box captures it on mouse up and appends it to the
/// transcript as an `[image N]` placeholder. Our own overlay, because macOS's screenshot tool
/// resizes from the center while Option is held.
@MainActor
final class LiveEditScreenshot {
    static let shared = LiveEditScreenshot()

    private var panels: [NSPanel] = []
    private var isDragging = false

    private init() {}

    func begin() {
        guard self.panels.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            DebugLogger.shared.warning("Hold to Capture Screenshot needs Screen Recording permission", source: "LiveEdit")
            CGRequestScreenCaptureAccess()
            return
        }
        self.panels = NSScreen.screens.map(self.makePanel(on:))
        self.panels.forEach { $0.orderFrontRegardless() }
        // A key panel makes FluidVoice active without bringing it forward, which the crosshair needs.
        // Ordering the panels out hands typing back to the target app.
        let mouse = NSEvent.mouseLocation
        (self.panels.first { $0.frame.contains(mouse) } ?? self.panels.first)?.makeKey()
    }

    /// The key went up or another modifier joined it. A box being dragged still captures on mouse up.
    func modifierReleased() {
        guard !self.isDragging else { return }
        self.dismiss()
    }

    private func dismiss() {
        self.isDragging = false
        self.panels.forEach { $0.orderOut(nil) }
        self.panels = []
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onDragStart = { [weak self] in self?.isDragging = true }
        view.onFinish = { [weak self] rect in
            guard let self else { return }
            self.isDragging = false
            if let rect {
                self.dismiss()
                Task { await Self.capture(rect, on: screen) }
            } else if SettingsStore.shared.holdToCaptureModifier?.isHeld != true {
                self.dismiss()
            }
        }
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        return panel
    }

    private static func capture(_ rect: NSRect, on screen: NSScreen) async {
        do {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
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
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            LiveEditSession.shared.appendScreenshot(at: try LiveEditImagePaste.save(png))
        } catch {
            DebugLogger.shared.error("Hold to Capture Screenshot failed: \(error.localizedDescription)", source: "LiveEdit")
        }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dims the screen slightly so the mode is visible, and draws the box being dragged.
private final class SelectionView: NSView {
    var onDragStart: (() -> Void)?
    /// The box in screen coordinates, or nil for a click without a box.
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.trackingAreas.forEach(self.removeTrackingArea)
        self.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    /// With several screens, the one under the pointer takes the key so its crosshair shows.
    override func mouseEntered(with _: NSEvent) {
        self.window?.makeKey()
        NSCursor.crosshair.set()
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        self.start = self.convert(event.locationInWindow, from: nil)
        self.current = self.start
        self.onDragStart?()
        self.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        self.current = self.convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        let box = self.selection.flatMap { $0.width >= 4 && $0.height >= 4 ? $0 : nil }
        self.start = nil
        self.current = nil
        self.needsDisplay = true
        self.onFinish?(box.flatMap { box in self.window.map { $0.convertToScreen(self.convert(box, to: nil)) } })
    }

    override func draw(_: NSRect) {
        // Fully clear pixels would let clicks through to the apps below.
        NSColor.black.withAlphaComponent(0.12).setFill()
        self.bounds.fill()
        guard let selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
