import Foundation

@main
enum LiveEditMergeTests {
    static func main() {
        self.testMerge()
        self.testEditedRanges()
        print("PASS: hand edits survive recognizer revisions, appends, the final pass, and deletions")
    }

    static func testMerge() {
        func merged(_ base: String, _ edited: String, _ recognized: String) -> String {
            LiveEditMerge.merge(base: base, edited: edited, recognized: recognized)
        }
        precondition(merged("a b", "a b", "a B c") == "a B c", "Without edits the recognizer wins")
        precondition(merged("quick fluid voice beta.", "quick FluidVoice beta.", "quick fluid voice beta. I tested")
            == "quick FluidVoice beta. I tested", "A fix survives new speech")
        precondition(merged("quick fluid voice beta.", "quick FluidVoice beta.", "quick Fluid Voice beta.")
            == "quick FluidVoice beta.", "The hand edit wins over a final-pass rewrite")
        precondition(merged("merge up stream main Sonora build.", "merge up stream main Sonoma build.", "merge upstream main Sonora build.")
            == "merge upstream main Sonoma build.", "Untouched words take the recognizer's fix")
        precondition(merged("hello wor", "hello word", "hello world and more") == "hello word and more",
                     "Fixing the newest word keeps the words that arrive after it")
        precondition(merged("at the end.", "at the end. Screenshot attached.", "at the end. Next I")
            == "at the end. Screenshot attached. Next I", "A note at the end stays before later speech")
        precondition(merged("a b c d", "a d", "a b c d e") == "a d e", "A deletion survives an append")
        precondition(merged("one two", "one\ntwo", "one two three") == "one\ntwo three", "A typed line break survives")
        precondition(merged("hello", "hello world", "") == "hello world", "Typed text survives an empty final pass")
        precondition(merged("I am hel", "I am hel [image 1]", "I am hello there") == "I am hello [image 1] there",
                     "An image appended after the newest words keeps their revision, and new speech follows it")
        precondition(merged("I am hello there", "I am hello [image 1] there", "I am hello there.") == "I am hello [image 1] there.",
                     "Words next to an inserted image still take the final pass's fix")
    }

    static func testEditedRanges() {
        func marked(_ recognized: String, _ edited: String) -> [String] {
            LiveEditMerge.editedRanges(recognized: recognized, edited: edited).map { (edited as NSString).substring(with: $0) }
        }
        precondition(marked("merge upstream main Sonora build.", "merge upstream main Sonoma build.") == ["Sonoma"])
        precondition(marked("a b c", "a x y c") == ["x y"], "Adjacent edited words form one range")
        precondition(marked("a b c", "x b y") == ["x", "y"])
        precondition(marked("a b", "a b").isEmpty)
        precondition(marked("café ok", "café 👍 ok") == ["👍"], "Ranges are UTF-16")
    }
}
