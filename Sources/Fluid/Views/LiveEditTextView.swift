import AppKit
import SwiftUI

/// ⌘↩ stops the dictation and pastes, with the Hold to Auto-Send key held also sends.
private final class LiveEditNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command), let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The editable transcript inside the notch while Live Edit is open.
struct LiveEditTextView: NSViewRepresentable {
    @ObservedObject var session: LiveEditSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: self.session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, so hand-edit highlights can be temporary attributes outside the text and undo.
        let textView = LiveEditNSTextView(usingTextLayoutManager: false)
        // Read the send key now: Hold to Auto-Send normally checks it at paste time, after AI enhancement.
        textView.onCommandReturn = { self.session.requestStop(send: SettingsStore.shared.holdToSendModifier?.isHeld == true) }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .fluidSystemFont(ofSize: 12)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = .white
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = self.session.text
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.refreshHighlights()
        DispatchQueue.main.async { context.coordinator.focusIfNeeded() }
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.sync(to: self.session.text)
        context.coordinator.focusIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: LiveEditSession
        weak var textView: NSTextView?
        private var didFocus = false

        init(session: LiveEditSession) {
            self.session = session
        }

        /// The notch panel never activates FluidVoice, so the target app stays frontmost while the panel takes typing.
        func focusIfNeeded() {
            guard !self.didFocus, let textView, let window = textView.window else { return }
            self.didFocus = true
            window.makeKey()
            window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(self.session.openingCaret ?? length, length), length: 0))
            // Scroll once the notch has finished growing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        /// Applies a recognizer update as the smallest replacement, keeping the caret and scroll position.
        func sync(to text: String) {
            guard let textView, textView.string != text, let storage = textView.textStorage else { return }
            let old = textView.string as NSString, new = text as NSString
            let limit = min(old.length, new.length)
            var prefix = 0
            while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
                suffix += 1
            }
            func mapped(_ offset: Int) -> Int {
                if offset <= prefix { return offset }
                if offset >= old.length - suffix { return offset + new.length - old.length }
                return new.length - suffix
            }
            let selection = textView.selectedRange()
            let wasAtBottom = textView.enclosingScrollView.map { $0.contentView.bounds.maxY >= textView.frame.maxY - 4 } ?? true

            let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
            storage.replaceCharacters(
                in: NSRange(location: prefix, length: old.length - prefix - suffix),
                with: NSAttributedString(string: replacement, attributes: textView.typingAttributes)
            )
            // Recognizer updates bypass undo; a stale undo stack would rewrite the wrong words.
            textView.undoManager?.removeAllActions()
            let start = mapped(selection.location)
            textView.setSelectedRange(NSRange(location: start, length: max(0, mapped(NSMaxRange(selection)) - start)))
            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
            self.refreshHighlights()
        }

        func refreshHighlights() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
            for range in LiveEditMerge.editedRanges(recognized: self.session.recognizedText, edited: textView.string) {
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: NSColor(calibratedRed: 0.47, green: 0.8, blue: 0.72, alpha: 0.16),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor(calibratedRed: 0.51, green: 0.86, blue: 0.78, alpha: 0.75),
                ], forCharacterRange: range)
            }
        }

        func textDidChange(_: Notification) {
            guard let textView else { return }
            self.session.userEdited(textView.string)
            self.refreshHighlights()
        }

        func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            self.session.close(restoreFocus: true)
            return true
        }
    }
}
