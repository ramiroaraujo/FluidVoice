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
        let saved = try! LiveEditImagePaste.paths(from: board, folder: folder)
        precondition(saved?.count == 1, "Image data pastes as one path")
        let savedURL = URL(fileURLWithPath: saved![0])
        precondition(savedURL.pathExtension == "png" && savedURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        precondition(NSImage(contentsOf: savedURL) != nil, "The saved file is a readable image")

        board.clearContents()
        board.writeObjects([savedURL as NSURL])
        precondition(try! LiveEditImagePaste.paths(from: board, folder: folder) == [savedURL.path], "A copied image file pastes its own path")

        board.clearContents()
        board.writeObjects([image, "caption" as NSString])
        precondition(try! LiveEditImagePaste.paths(from: board, folder: folder) == nil, "Text copied with an image pastes as text")

        board.clearContents()
        board.setString("plain text", forType: .string)
        precondition(try! LiveEditImagePaste.paths(from: board, folder: folder) == nil)

        print("PASS: image data saves as a PNG path, image files paste their path, text stays text")
    }
}
