import AppKit
import UniformTypeIdentifiers

/// Pasting into Live Edit: CLI prompts take no inline images, so images paste as file paths.
/// Copied image files keep their own path; image data is saved as a PNG in the temporary folder.
nonisolated enum LiveEditImagePaste {
    /// Nil when the pasteboard holds no image; throws when an image could not be saved.
    static func paths(from pasteboard: NSPasteboard, folder: URL = Self.defaultFolder) throws -> [String]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        // Text copied together with images still pastes as text.
        guard pasteboard.string(forType: .string) == nil, let png = self.pngData(from: pasteboard) else { return nil }
        let file = folder.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: file)
        return [file.path]
    }

    static let defaultFolder = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoiceLiveEdit", isDirectory: true)

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
