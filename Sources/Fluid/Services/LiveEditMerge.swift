import Foundation

/// Word-level three-way merge between Live Edit hand edits and the recognizer.
///
/// `base` is the recognizer text the editor last synced to, `edited` is the editor text,
/// and `recognized` is newer recognizer text. Words only the recognizer changed take its
/// version; words only the user changed keep the hand edit; where both changed the same
/// words, the hand edit wins.
nonisolated enum LiveEditMerge {
    static func merge(base: String, edited: String, recognized: String) -> String {
        guard edited != base else { return recognized }
        let baseTokens = self.tokenize(base), editedTokens = self.tokenize(edited), recognizedTokens = self.tokenize(recognized)
        let baseKeys = baseTokens.map(self.key), editedKeys = editedTokens.map(self.key), recognizedKeys = recognizedTokens.map(self.key)
        let toEdited = self.align(baseKeys, editedKeys), toRecognized = self.align(baseKeys, recognizedKeys)

        var output: [Substring] = []
        var baseStart = 0, editedStart = 0, recognizedStart = 0
        for index in 0...baseTokens.count {
            let atEnd = index == baseTokens.count
            let editedEnd: Int, recognizedEnd: Int
            if atEnd {
                editedEnd = editedTokens.count
                recognizedEnd = recognizedTokens.count
            } else {
                // Only words all three texts share anchor a chunk.
                guard let e = toEdited[index], let r = toRecognized[index] else { continue }
                editedEnd = e
                recognizedEnd = r
            }
            let baseChunk = baseKeys[baseStart..<index]
            let editedChunk = editedKeys[editedStart..<editedEnd], recognizedChunk = recognizedKeys[recognizedStart..<recognizedEnd]
            let editedText = editedTokens[editedStart..<editedEnd], recognizedText = recognizedTokens[recognizedStart..<recognizedEnd]

            if recognizedChunk.elementsEqual(baseChunk) || editedChunk.elementsEqual(recognizedChunk) {
                output += editedText
            } else if editedChunk.elementsEqual(baseChunk) {
                output += recognizedText
            } else if baseChunk.isEmpty {
                // Both added text at the same spot: the hand edit goes first.
                output += editedText
                output += recognizedText
            } else if recognizedChunk.count >= baseChunk.count,
                      let kept = editedChunk.indices.first(where: { editedKeys[$0..<editedEnd].starts(with: baseChunk) }) {
                // The user only added words around these, like an image pasted after the newest words:
                // they still take the recognizer's revision, and newer speech goes after the additions.
                let revised = recognizedStart + baseChunk.count
                output += editedTokens[editedStart..<kept]
                output += recognizedTokens[recognizedStart..<revised]
                output += editedTokens[(kept + baseChunk.count)..<editedEnd]
                output += recognizedTokens[revised..<recognizedEnd]
            } else if atEnd, recognizedChunk.count > baseChunk.count {
                // The user fixed the newest words while more speech arrived.
                output += editedText
                output += recognizedTokens[(recognizedStart + baseChunk.count)..<recognizedEnd]
            } else {
                output += editedText
            }
            if !atEnd { output.append(editedTokens[editedEnd]) }
            baseStart = index + 1
            editedStart = editedEnd + 1
            recognizedStart = recognizedEnd + 1
        }
        return self.join(output)
    }

    /// UTF-16 ranges of `edited` the user typed or changed, relative to `recognized`.
    /// Adjacent changed words form one range.
    static func editedRanges(recognized: String, edited: String) -> [NSRange] {
        let tokens = self.tokenize(edited)
        let matches = self.align(tokens.map(self.key), self.tokenize(recognized).map(self.key))
        var ranges: [NSRange] = []
        var location = 0
        var previousEdited = false
        for (index, token) in tokens.enumerated() {
            let word = self.key(token)
            let isEdited = matches[index] == nil && !word.isEmpty
            if isEdited {
                let end = location + word.utf16.count
                if previousEdited, let last = ranges.popLast() {
                    ranges.append(NSRange(location: last.location, length: end - last.location))
                } else {
                    ranges.append(NSRange(location: location, length: end - location))
                }
            }
            previousEdited = isEdited
            location += token.utf16.count
        }
        return ranges
    }

    /// A word plus the whitespace after it. Only the first token can be bare whitespace.
    private static func tokenize(_ text: String) -> [Substring] {
        var tokens: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            if tokens.isEmpty, text[start].isWhitespace {
                while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            } else {
                while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            }
            tokens.append(text[start..<end])
            start = end
        }
        return tokens
    }

    private static func key(_ token: Substring) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For each element of `a`, the index of the same element in `b` along a common subsequence.
    private static func align(_ a: [String], _ b: [String]) -> [Int?] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var matches = [Int?](repeating: nil, count: a.count)
        var next = 0
        for index in a.indices where !removed.contains(index) {
            while inserted.contains(next) { next += 1 }
            matches[index] = next
            next += 1
        }
        return matches
    }

    private static func join(_ tokens: [Substring]) -> String {
        var text = ""
        for token in tokens where !token.isEmpty {
            if let last = text.last, !last.isWhitespace, let first = token.first, !first.isWhitespace {
                text += " "
            }
            text += token
        }
        return text
    }
}
