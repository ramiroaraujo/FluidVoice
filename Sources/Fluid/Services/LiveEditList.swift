import Foundation

/// Markdown list continuation for Return in the Live Edit editor.
nonisolated enum LiveEditList {
    enum Action: Equatable {
        /// Insert this at the caret: a line break and the next item's marker.
        case insert(String)
        /// The item is empty: remove its marker, which ends the list.
        case endList
    }

    /// `beforeCaret` runs from the line start to the caret, `afterCaret` from the caret to the line end.
    /// Nil when the line is not a `*`, `-` or `1.` / `1)` list item, so Return inserts a plain line break.
    static func onReturn(beforeCaret: String, afterCaret: String) -> Action? {
        let indent = beforeCaret.prefix(while: { $0 == " " || $0 == "\t" })
        var rest = beforeCaret.dropFirst(indent.count)
        let next: String
        if let bullet = rest.first, bullet == "*" || bullet == "-" {
            next = String(bullet)
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard digits.count < 10, let number = Int(digits),
                  let separator = rest.dropFirst(digits.count).first, separator == "." || separator == ")"
            else { return nil }
            next = "\(number + 1)\(separator)"
            rest = rest.dropFirst(digits.count + 1)
        }
        let gap = rest.prefix(while: { $0 == " " || $0 == "\t" })
        guard !gap.isEmpty else { return nil }
        if rest.allSatisfy(\.isWhitespace), afterCaret.allSatisfy(\.isWhitespace) { return .endList }
        return .insert("\n" + indent + next + gap)
    }
}
