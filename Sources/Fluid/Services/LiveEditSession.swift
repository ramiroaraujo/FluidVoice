import AppKit
import Combine
import SwiftUI

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
    /// Links pasted into the editor; the AI cleanup keeps them as written.
    private(set) var links: [String] = []
    /// The clipboard's change count when its image or link was last pasted; the Paste buttons hide until it changes.
    @Published private(set) var pastedClipboardChangeCount: Int?
    /// What was last added after the newest words; a Shift+Enter while the text still ends with it breaks the line after it.
    private var lastAppended: String?
    /// Adds the Shift+Enter line breaks and the new-line cursor to the text the overlay shows. Set by MenuBarManager.
    var previewText: (String) -> String = { $0 }
    /// A key press in the editor; the recording holds or drops the audio around it. Set by MenuBarManager.
    var onKeyPressed: (() -> Void)?

    /// The open editor's text view. Set by LiveEditTextView.
    weak var editor: NSTextView?

    var hasEdits: Bool { self.text != self.recognizedText }

    /// Shift Shift with the editor open: closes it when it has typing focus, and gives it typing focus back
    /// when another window took it.
    func toggleFocusOrClose() {
        guard self.isOpen, let editor, let window = editor.window else { return }
        if window.isKeyWindow, window.firstResponder === editor {
            self.close(restoreFocus: true)
        } else {
            self.focusEditor()
        }
    }

    /// Gives the open editor typing focus; the screenshot selector takes it while it shows.
    func focusEditor() {
        guard self.isOpen, let editor, let window = editor.window else { return }
        window.makeKey()
        window.makeFirstResponder(editor)
    }

    private init() {}

    /// Takes the recognizer's full transcript and returns the text the overlay should show.
    func ingest(_ recognized: String, isRecording: Bool) -> String {
        // The recognizer clears its transcript only when a recording starts or is cancelled.
        guard !recognized.isEmpty else {
            // The editor can open before the first words; what is typed there stays.
            if self.isOpen, isRecording, self.recognizedText.isEmpty { return self.text }
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
        return self.placeholders(forImagesAt: paths)
    }

    /// The notch's Paste Image button: the images go after the newest words, and speech continues after them.
    func pasteImagesAtEnd() {
        guard let placeholders = self.clipboardImagePlaceholders() else { return }
        self.appendAtEnd(placeholders)
    }

    /// Returns the clipboard's link, or nil when the clipboard holds none.
    func clipboardLink() -> String? {
        guard let link = LiveEditImagePaste.link(from: .general) else { return nil }
        self.pastedClipboardChangeCount = NSPasteboard.general.changeCount
        self.links.append(link)
        return link
    }

    /// The notch's Paste Link button: the link goes after the newest words, like the Paste Image button.
    func pasteLinkAtEnd() {
        guard let link = self.clipboardLink() else { return }
        self.appendAtEnd(link)
    }

    /// ⇧⌘V while recording: the clipboard's image, link or text goes after the newest words.
    func pasteClipboardAtEnd() {
        if let insertion = self.clipboardImagePlaceholders() ?? self.clipboardLink() { return self.appendAtEnd(insertion) }
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        self.appendAtEnd(text)
    }

    /// Local API: text another app sends goes after the newest words, like ⇧⌘V.
    func appendText(_ text: String) {
        self.appendAtEnd(text)
    }

    /// Hold to Capture Screenshot and the local API: the image goes after the newest words, like the Paste Image button.
    func appendScreenshot(at path: String) {
        self.appendAtEnd(self.placeholders(forImagesAt: [path]))
    }

    private func placeholders(forImagesAt paths: [String]) -> String {
        paths.map { path in
            self.imagePaths.append(path)
            return "[image \(self.imagePaths.count)]"
        }.joined(separator: " ")
    }

    private func appendAtEnd(_ insertion: String) {
        self.text += (self.text.last?.isWhitespace ?? true ? "" : " ") + insertion
        self.lastAppended = insertion
        NotchOverlayManager.shared.updateTranscriptionText(self.previewText(self.text))
    }

    /// Shift+Enter right after a paste: the break is typed after the pasted item, since no spoken word
    /// marks that spot in the audio. Returns false once speech has followed the paste.
    func breakLineAfterPaste() -> Bool {
        guard let lastAppended, self.text.trimmingCharacters(in: .newlines).hasSuffix(lastAppended) else { return false }
        self.text += "\n"
        NotchOverlayManager.shared.updateTranscriptionText(self.previewText(self.text))
        return true
    }

    /// Animated as a transaction so DynamicNotchKit's notch shape, outside the content view, grows and shrinks with it.
    private static let resizeAnimation = Animation.snappy(duration: 0.22)

    /// `allowingEmpty` opens the editor before any words exist, to type first and talk after.
    func open(caret: Int? = nil, allowingEmpty: Bool = false) {
        guard !self.isOpen, allowingEmpty || !self.text.isEmpty else { return }
        self.openingCaret = caret
        withAnimation(Self.resizeAnimation) { self.isOpen = true }
    }

    func requestStop(send: Bool) {
        guard self.isOpen else { return }
        self.sendRequested = send
        self.onStopRequested?()
    }

    func close(restoreFocus: Bool) {
        guard self.isOpen else { return }
        withAnimation(Self.resizeAnimation) { self.isOpen = false }
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
    /// and ends the session. Returns the image paths and links the text contains, and the runs of words the user
    /// typed; the AI cleanup must keep both as written.
    func finish(finalTranscript: String) -> (text: String, protectedText: [String], typedText: [String]) {
        defer { self.reset() }
        guard self.hasEdits else { return (finalTranscript, [], []) }
        DebugLogger.shared.info("Live Edit merged hand edits into the final transcript", source: "LiveEdit")
        var text = LiveEditMerge.merge(base: self.recognizedText, edited: self.text, recognized: finalTranscript)
        let typedText = LiveEditMerge.editedRanges(recognized: finalTranscript, edited: text)
            .map { (text as NSString).substring(with: $0) }
            .filter { !$0.hasPrefix("[image ") && !self.links.contains($0) }
        var usedPaths: [String] = []
        for (index, path) in self.imagePaths.enumerated() {
            let placeholder = "[image \(index + 1)]"
            guard text.contains(placeholder) else { continue }
            text = text.replacingOccurrences(of: placeholder, with: path)
            usedPaths.append(path)
        }
        return (text, usedPaths + self.links.filter { text.contains($0) }, typedText)
    }

    private func reset() {
        self.isOpen = false
        self.text = ""
        self.recognizedText = ""
        self.openingCaret = nil
        self.sendRequested = false
        self.imagePaths = []
        self.links = []
        self.lastAppended = nil
        self.pastedClipboardChangeCount = nil
    }
}
