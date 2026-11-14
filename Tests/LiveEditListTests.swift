import Foundation

@main
enum LiveEditListTests {
    static func main() {
        func onReturn(_ before: String, _ after: String = "") -> LiveEditList.Action? {
            LiveEditList.onReturn(beforeCaret: before, afterCaret: after)
        }
        precondition(onReturn("* milk") == .insert("\n* "), "A star item continues")
        precondition(onReturn("- milk") == .insert("\n- "), "A dash item continues")
        precondition(onReturn("  * nested") == .insert("\n  * "), "Indentation carries over")
        precondition(onReturn("1. uno") == .insert("\n2. "), "Numbers count up")
        precondition(onReturn("9) nine") == .insert("\n10) "), "Parenthesis numbering counts up")
        precondition(onReturn("* foo", "bar\n") == .insert("\n* "), "Return mid-item splits it into two items")
        precondition(onReturn("* ") == .endList && onReturn("3.  ", "\n") == .endList, "An empty item ends the list")
        precondition(onReturn("* ", "bar") == .insert("\n* "), "An item with text after the caret is not empty")
        precondition(onReturn("plain text") == nil && onReturn("*bold*") == nil && onReturn("2026.") == nil,
                     "Lines that aren't list items get a plain line break")
        precondition(onReturn("") == nil && onReturn("1.5 liters") == nil)
        print("PASS: Live Edit list continuation for bullets and numbers")
    }
}
