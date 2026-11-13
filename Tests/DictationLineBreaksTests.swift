import Foundation

@main
enum DictationLineBreaksTests {
    static func main() {
        func breaks(_ words: String, _ positions: [Int]) -> DictationLineBreaks {
            DictationLineBreaks(words: words.split(separator: " ").map(String.init), positions: positions)
        }
        // Unchanged text.
        precondition(breaks("first line. second line.", [2]).apply(to: "first line. second line.") == "first line.\nsecond line.")
        // Removed filler right at the break, punctuation and case changes.
        precondition(breaks("um so I think um we should", [4]).apply(to: "So I think we should.") == "So I think\nwe should.")
        // A dictionary fix just after or just before the break.
        precondition(breaks("done work tree is ready", [1]).apply(to: "done worktree is ready") == "done\nworktree is ready")
        precondition(breaks("the work tree is ready", [3]).apply(to: "the worktree is ready") == "the worktree\nis ready")
        // Repeated presses stack; edge breaks are dropped.
        precondition(breaks("one two three", [0, 1, 1, 3]).apply(to: "one two three") == "one\n\ntwo three")
        // Several breaks, words that start before the press stay before it.
        let timed = DictationLineBreaks(
            words: ["a", "b", "c", "d"].enumerated().map { ASRWordTiming(text: $1, start: Double($0), end: Double($0) + 0.8) },
            breakSeconds: [0.9, 2.5]
        )
        precondition(timed?.positions == [1, 3])
        precondition(timed?.apply(to: "A, b, c, d.") == "A,\nb, c,\nd.")
        precondition(DictationLineBreaks(words: [], breakSeconds: [1]) == nil)
        precondition(breaks("x y", [1]).apply(to: "single") == "single")
        // Preview: a trailing break shows a cursor until words follow it.
        precondition(breaks("one two", [2, 2]).preview("One two.") == "One two.\n\n▍")
        precondition(breaks("one", [1]).preview("One, two") == "One,\ntwo")
        precondition(breaks("one two", [1]).preview("one two") == "one\ntwo")
        print("DictationLineBreaksTests passed")
    }
}
