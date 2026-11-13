import Foundation

@main
enum DictationTypingHoldTests {
    static func main() {
        var hold = DictationTypingHold()
        precondition(hold.route([1], at: 0) == [1], "Without a key press audio passes through")

        hold.keyPressed(at: 100, windowTicks: 50)
        precondition(hold.route([2], at: 110).isEmpty, "Audio after a key press waits")
        hold.keyPressed(at: 120, windowTicks: 50)
        precondition(hold.route([3], at: 130).isEmpty)
        precondition(hold.route([4], at: 180) == [Float](repeating: 0, count: 1600) + [3, 4],
                     "Audio between two close key presses is dropped; audio after the last one is kept whole")
        precondition(hold.route([5], at: 190) == [5], "The hold ends once the window passes")

        hold.keyPressed(at: 200, windowTicks: 50)
        _ = hold.route([6], at: 210)
        precondition(hold.release() == [6], "A stop inside the window keeps the held audio")
        precondition(hold.route([7], at: 220) == [7])
        print("PASS: the typing hold drops audio between close key presses and keeps what follows the last")
    }
}
