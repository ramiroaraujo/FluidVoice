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

    /// `vocabulary` lists the user's dictionary spellings. A blank prompt means "no
    /// instructions", so it stays blank.
    init(promptText: String, transcript: String, vocabulary: [String] = []) {
        var promptText = promptText
        if !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let instruction = Self.vocabularyInstruction(vocabulary)
        {
            promptText += "\n\n" + instruction
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

    static func renderTemplate(promptText: String, transcript: String) -> String {
        if promptText.contains("${transcript}") {
            return promptText.replacingOccurrences(of: "${transcript}", with: transcript)
        }
        if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return transcript }
        return promptText + "\n\n" + transcript
    }
}
