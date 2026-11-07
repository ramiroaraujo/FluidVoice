import AppKit
import UniformTypeIdentifiers

/// Pasting into Live Edit: CLI prompts take no inline images, so images paste as file paths.
/// Copied image files keep their own path; image data is saved as a PNG in the temporary folder.
/// Links paste as themselves.
nonisolated enum LiveEditImagePaste {
    /// Nil when the pasteboard holds no image; throws when an image could not be saved.
    static func paths(from pasteboard: NSPasteboard, folder: URL = Self.defaultFolder) throws -> [String]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: self.imageFileOptions) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        // Text copied together with images still pastes as text.
        guard pasteboard.availableType(from: [.string]) == nil, let png = self.pngData(from: pasteboard) else { return nil }
        return try [self.save(png, in: folder)]
    }

    /// Writes PNG data to a new file in `folder` and returns its path.
    static func save(_ png: Data, in folder: URL = Self.defaultFolder) throws -> String {
        let file = folder.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: file)
        return file.path
    }

    /// Whether `paths(from:)` would find images, checked from the pasteboard types without reading image data.
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: self.imageFileOptions)
            || (pasteboard.availableType(from: [.string]) == nil && pasteboard.canReadObject(forClasses: [NSImage.self]))
    }

    /// The copied text when it is a single URI with a scheme, like https://…, mailto:… or slack://…; nil otherwise.
    static func link(from pasteboard: NSPasteboard) -> String? {
        // Password managers mark copied secrets as concealed; those are never offered.
        guard pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) != true,
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:\S+$"#, options: .regularExpression) != nil
        else { return nil }
        return text
    }

    static let defaultFolder = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoiceLiveEdit", isDirectory: true)

    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
