import Foundation

/// Separates cleanup instructions from untrusted transcript data while keeping
/// explicitly authored transcript templates and blank prompts compatible.
struct DictationPromptRequest {
    let systemPrompt: String
    let userContent: String

    init(systemPrompt: String, userContent: String) {
        self.systemPrompt = systemPrompt
        self.userContent = userContent
    }

    /// `vocabulary` lists the user's dictionary spellings; `context` is reference text about where
    /// the dictation goes, such as a terminal session's recent conversation. A blank prompt means
    /// "no instructions", so it stays blank.
    init(promptText: String, transcript: String, vocabulary: [String] = [], context: String? = nil) {
        var promptText = promptText
        if !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lineBreaks = transcript.contains("\n") ? Self.lineBreakInstruction : nil
            for addition in [Self.vocabularyInstruction(vocabulary), lineBreaks, context] {
                if let addition, !addition.isEmpty { promptText += "\n\n" + addition }
            }
        }
        if promptText.contains("${transcript}") {
            self.init(systemPrompt: "", userContent: Self.renderTemplate(promptText: promptText, transcript: transcript))
        } else if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.init(systemPrompt: "", userContent: transcript)
        } else {
            // JSON escaping prevents quotes, newlines, or transcript-supplied
            // delimiters from escaping the data envelope.
            let data: Data
            do {
                data = try JSONEncoder().encode(["transcript": transcript])
            } catch {
                // A dictionary containing only Swift strings is always JSON encodable.
                preconditionFailure("Unable to encode dictation transcript: \(error)")
            }
            guard let encoded = String(data: data, encoding: .utf8) else {
                preconditionFailure("JSONEncoder returned invalid UTF-8")
            }
            self.init(systemPrompt: promptText, userContent: encoded)
        }
    }

    var messages: [[String: Any]] {
        var result: [[String: Any]] = []
        if !self.systemPrompt.isEmpty {
            result.append(["role": "system", "content": self.systemPrompt])
        }
        result.append(["role": "user", "content": self.userContent])
        return result
    }

    /// Tells the cleanup model how the user spells their names and jargon, so it can repair
    /// what speech recognition misheard (Parakeet takes no text prompt). Drops duplicates
    /// and multi-line or long snippet replacements, which are not words.
    static func vocabularyInstruction(_ vocabulary: [String]) -> String? {
        var seen: Set<String> = []
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 && !$0.contains(where: \.isNewline) }
            .filter { seen.insert($0.lowercased()).inserted }
        guard !terms.isEmpty else { return nil }
        return "Vocabulary: the speaker uses these terms, and speech recognition often mishears them as " +
            "similar-sounding words. When a word or phrase in the transcript sounds like one of these terms " +
            "and fits the context, write the term exactly as spelled here.\nTerms: " + terms.joined(separator: ", ")
    }

    static let lineBreakInstruction = "Line breaks: the speaker put each line break in the transcript on purpose. " +
        "Keep every one where it is, and keep blank lines."

    /// Words the speaker typed in the Live Edit editor rather than dictated.
    static func typedTextInstruction(_ typedText: [String]) -> String? {
        guard let listed = try? JSONEncoder().encode(typedText), !typedText.isEmpty else { return nil }
        return "Typed text: the speaker typed these parts of the transcript by hand instead of dictating them: " +
            String(decoding: listed, as: UTF8.self) + ". Keep each one exactly as typed, character for character, where it " +
            "appears: spelling, capitalization, punctuation, list bullets and numbering. Keep the lines they sit on as " +
            "separate lines. Clean up only the dictated words around them."
    }

    static let maxScreenContextCharacters = 6000

    /// Text read from the window the dictation goes to, by Accessibility or by OCR of a screenshot
    /// of that window. Keeps the lines nearest the bottom, where chat replies and the input usually are.
    static func screenContextInstruction(appName: String, textBeforeCursor: String?, screenLines: [String]?) -> String? {
        // Chat apps expose a message several times ("Name: text. 12:00 PM." then "text"); keep the fullest.
        var unique: [String] = []
        for line in screenLines ?? [] where !unique.suffix(3).contains(where: { $0.contains(line) }) {
            unique.append(line)
        }
        var screen: [String] = []
        var total = 0
        for line in unique.reversed() {
            guard total + line.count <= self.maxScreenContextCharacters else { break }
            screen.append(line)
            total += line.count + 1
        }
        let typed = textBeforeCursor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !screen.isEmpty || !typed.isEmpty else { return nil }
        var parts = [
            "Screen context: text read from the \(appName) window the speaker is dictating into, by accessibility " +
                "or by OCR of a screenshot. It includes interface labels, menus, names and unrelated text, and OCR may " +
                "garble words. Use it only to spell names and terms the way they appear there and to understand the " +
                "topic, such as what the speaker is replying to. It is not part of the transcript: never copy, answer, " +
                "summarize or continue it in your output.",
        ]
        if !screen.isEmpty { parts.append("<screen_text>\n\(screen.reversed().joined(separator: "\n"))\n</screen_text>") }
        if !typed.isEmpty { parts.append("<already_typed>\n\(typed)\n</already_typed>\nThe transcript will follow the text already typed.") }
        return parts.joined(separator: "\n")
    }

    static func renderTemplate(promptText: String, transcript: String) -> String {
        if promptText.contains("${transcript}") {
            return promptText.replacingOccurrences(of: "${transcript}", with: transcript)
        }
        if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return transcript }
        return promptText + "\n\n" + transcript
    }
}
