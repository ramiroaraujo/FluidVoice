import AppKit
import Combine

/// Live Edit: the hand-editable copy of the live dictation transcript in the notch.
/// Recognizer updates and hand edits are merged, so speech keeps arriving while the user edits.
@MainActor
final class LiveEditSession: ObservableObject {
    static let shared = LiveEditSession()

    @Published private(set) var isOpen = false
    /// The recognizer's text plus the user's hand edits.
    @Published private(set) var text = ""
    /// Recognizer text the editor last synced to; equal to `text` until the user edits.
    private(set) var recognizedText = ""
    /// UTF-16 caret offset to place when the editor opens; nil puts it at the end.
    private(set) var openingCaret: Int?
    /// Set when the editor stopped the dictation with the Hold to Auto-Send key held;
    /// the paste is followed by the send key.
    private(set) var sendRequested = false
    /// Stops the dictation the way the hotkey does. Set by ContentView.
    var onStopRequested: (() -> Void)?
    /// Files behind the `[image N]` placeholders pasted into the editor; N is the index plus one.
    private(set) var imagePaths: [String] = []
    /// The clipboard's change count when its image was last pasted; the Paste Image button hides until it changes.
    @Published private(set) var pastedClipboardChangeCount: Int?

    var hasEdits: Bool { self.text != self.recognizedText }

    private init() {}

    /// Takes the recognizer's full transcript and returns the text the overlay should show.
    func ingest(_ recognized: String) -> String {
        // The recognizer clears its transcript only when a recording starts or is cancelled.
        guard !recognized.isEmpty else {
            self.reset()
            return ""
        }
        self.text = self.hasEdits
            ? LiveEditMerge.merge(base: self.recognizedText, edited: self.text, recognized: recognized)
            : recognized
        self.recognizedText = recognized
        return self.text
    }

    func userEdited(_ text: String) {
        self.text = text
    }

    /// Saves the clipboard's images and returns the `[image N]` placeholders that stand for them,
    /// or nil when the clipboard holds no image.
    func clipboardImagePlaceholders() -> String? {
        let paths: [String]?
        do {
            paths = try LiveEditImagePaste.paths(from: .general)
        } catch {
            DebugLogger.shared.error("Live Edit could not save a pasted image: \(error.localizedDescription)", source: "LiveEdit")
            return nil
        }
        guard let paths else { return nil }
        self.pastedClipboardChangeCount = NSPasteboard.general.changeCount
        return paths.map { path in
            self.imagePaths.append(path)
            return "[image \(self.imagePaths.count)]"
        }.joined(separator: " ")
    }

    /// The notch's Paste Image button: the images go after the newest words, and speech continues after them.
    func pasteImagesAtEnd() {
        guard let placeholders = self.clipboardImagePlaceholders() else { return }
        self.text += (self.text.last?.isWhitespace ?? true ? "" : " ") + placeholders
        NotchOverlayManager.shared.updateTranscriptionText(self.text)
    }

    func open(caret: Int? = nil) {
        guard !self.isOpen, !self.text.isEmpty else { return }
        self.openingCaret = caret
        self.isOpen = true
    }

    func requestStop(send: Bool) {
        guard self.isOpen else { return }
        self.sendRequested = send
        self.onStopRequested?()
    }

    func close(restoreFocus: Bool) {
        guard self.isOpen else { return }
        self.isOpen = false
        if restoreFocus {
            self.returnFocusToTarget()
        } else {
            NotchOverlayManager.shared.releaseNotchKeyFocus()
        }
    }

    /// Hands typing focus from the notch panel back to the app being dictated into.
    private func returnFocusToTarget() {
        guard NotchOverlayManager.shared.releaseNotchKeyFocus(), let context = NotchContentState.shared.recordingTargetContext else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await TypingService.prepareTargetForDelivery(context)
        }
    }

    /// Merges the final transcript under the hand edits, swaps image placeholders for their file paths,
    /// and ends the session. Returns the paths the text contains.
    func finish(finalTranscript: String) -> (text: String, imagePaths: [String]) {
        defer { self.reset() }
        guard self.hasEdits else { return (finalTranscript, []) }
        DebugLogger.shared.info("Live Edit merged hand edits into the final transcript", source: "LiveEdit")
        var text = LiveEditMerge.merge(base: self.recognizedText, edited: self.text, recognized: finalTranscript)
        var usedPaths: [String] = []
        for (index, path) in self.imagePaths.enumerated() {
            let placeholder = "[image \(index + 1)]"
            guard text.contains(placeholder) else { continue }
            text = text.replacingOccurrences(of: placeholder, with: path)
            usedPaths.append(path)
        }
        return (text, usedPaths)
    }

    private func reset() {
        self.isOpen = false
        self.text = ""
        self.recognizedText = ""
        self.openingCaret = nil
        self.sendRequested = false
        self.imagePaths = []
        self.pastedClipboardChangeCount = nil
    }
}
