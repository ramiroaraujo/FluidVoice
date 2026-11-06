import Combine
import Foundation

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
        NotchOverlayManager.shared.releaseNotchKeyFocus()
        guard restoreFocus, let context = NotchContentState.shared.recordingTargetContext else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await TypingService.prepareTargetForDelivery(context)
        }
    }

    /// Merges the final transcript under the hand edits and ends the session.
    func finish(finalTranscript: String) -> String {
        defer { self.reset() }
        guard self.hasEdits else { return finalTranscript }
        DebugLogger.shared.info("Live Edit merged hand edits into the final transcript", source: "LiveEdit")
        return LiveEditMerge.merge(base: self.recognizedText, edited: self.text, recognized: finalTranscript)
    }

    private func reset() {
        self.isOpen = false
        self.text = ""
        self.recognizedText = ""
        self.openingCaret = nil
        self.sendRequested = false
    }
}
