import AppKit

@main
enum LiveEditImagePasteTests {
    static func main() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fluidvoice-live-edit-paste-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard(name: NSPasteboard.Name("fluidvoice.live-edit-paste-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }

        board.clearContents()
        board.writeObjects([image])
        precondition(LiveEditImagePaste.hasImage(board), "Image data counts as an image")
        let saved = try! LiveEditImagePaste.paths(from: board, folder: folder)
        precondition(saved?.count == 1, "Image data pastes as one path")
        let savedURL = URL(fileURLWithPath: saved![0])
        precondition(savedURL.pathExtension == "png" && savedURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        precondition(NSImage(contentsOf: savedURL) != nil, "The saved file is a readable image")

        board.clearContents()
        board.writeObjects([savedURL as NSURL])
        precondition(LiveEditImagePaste.hasImage(board), "A copied image file counts as an image")
        precondition(try! LiveEditImagePaste.paths(from: board, folder: folder) == [savedURL.path], "A copied image file pastes its own path")

        board.clearContents()
        board.writeObjects([image, "caption" as NSString])
        precondition(!LiveEditImagePaste.hasImage(board), "Text copied with an image is not an image")
        precondition(try! LiveEditImagePaste.paths(from: board, folder: folder) == nil, "Text copied with an image pastes as text")

        board.clearContents()
        board.setString("plain text", forType: .string)
        precondition(!LiveEditImagePaste.hasImage(board))
        precondition(try! LiveEditImagePaste.paths(from: board, folder: folder) == nil)

        func link(_ text: String) -> String? {
            board.clearContents()
            board.setString(text, forType: .string)
            return LiveEditImagePaste.link(from: board)
        }
        precondition(link(" https://example.com/a?b=1#c\n") == "https://example.com/a?b=1#c", "A copied link pastes trimmed")
        precondition(link("mailto:me@example.com") != nil && link("slack://open?team=T1") != nil, "Any URI with a scheme is a link")
        precondition(link("plain text") == nil && link("see https://example.com") == nil, "Text around a link is not a link")
        precondition(link("10:30") == nil && link("example.com") == nil, "Text without a scheme is not a link")
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("https://example.com", forType: .string)
        precondition(LiveEditImagePaste.link(from: board) == nil, "A concealed copy, like a password, is never a link")
        board.clearContents()
        board.writeObjects([image])
        precondition(LiveEditImagePaste.link(from: board) == nil, "An image is not a link")

        print("PASS: image data saves as a PNG path, image files paste their path, links paste trimmed, text stays text")
    }
}
