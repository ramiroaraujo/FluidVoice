import Foundation

/// Line breaks typed with Shift+Enter while dictating. Each break sits after the words
/// the recognizer timed before the key press; `apply(to:)` carries it into the processed text.
nonisolated struct DictationLineBreaks: Equatable, Sendable {
    /// The recognizer's own words, before filler removal, dictionary or punctuation steps.
    let words: [String]
    /// For each break, how many of `words` come before it.
    let positions: [Int]

    init(words: [String], positions: [Int]) {
        self.words = words
        self.positions = positions
    }

    /// Words that start before the press go before the break.
    init?(words: [ASRWordTiming], breakSeconds: [TimeInterval]) {
        guard !words.isEmpty, !breakSeconds.isEmpty else { return nil }
        self.words = words.map(\.text)
        self.positions = breakSeconds.map { time in words.firstIndex { $0.start >= time } ?? words.count }
    }

    /// Places the breaks in `text` by matching its words to the recognizer's. A break inside a
    /// stretch the processing changed (a dictionary fix, a removed filler) lands proportionally.
    /// Breaks before the first word are dropped, and after the last word unless `keepsTrailing`;
    /// repeated presses stack.
    func apply(to text: String, keepsTrailing: Bool = false) -> String {
        let target = text.split(whereSeparator: \.isWhitespace)
        guard !target.isEmpty else { return text }
        func key(_ word: some StringProtocol) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let source = self.words.map(key)
        let difference = target.map(key).difference(from: source)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // Words the processing left alone, as (source index, target index).
        let kept = zip(source.indices.filter { !removed.contains($0) }, target.indices.filter { !inserted.contains($0) })
            .map { (source: $0, target: $1) }

        var counts: [Int: Int] = [:]
        for position in self.positions {
            let before = kept.last { $0.source < position }
            let after = kept.first { $0.source >= position }
            let sourceLow = (before?.source ?? -1) + 1, sourceHigh = after?.source ?? source.count
            let targetLow = (before?.target ?? -1) + 1, targetHigh = after?.target ?? target.count
            let share = sourceHigh > sourceLow ? Double(position - sourceLow) / Double(sourceHigh - sourceLow) : 0
            let index = targetLow + Int((share * Double(targetHigh - targetLow)).rounded())
            if index > 0, index < target.count || (keepsTrailing && index == target.count) { counts[index, default: 0] += 1 }
        }

        var output = ""
        var cursor = text.startIndex
        for (index, count) in counts.sorted(by: { $0.key < $1.key }) {
            output += text[cursor..<target[index - 1].endIndex]
            output += String(repeating: "\n", count: count)
            cursor = index < target.count ? target[index].startIndex : text.endIndex
        }
        output += text[cursor...]
        return output
    }

    /// The live preview: a break nothing follows yet shows a cursor on the new line.
    func preview(_ text: String) -> String {
        let shown = self.apply(to: text, keepsTrailing: true)
        return shown.hasSuffix("\n") ? shown + "▍" : shown
    }
}
