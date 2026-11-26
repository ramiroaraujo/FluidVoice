import AppKit

/// GET /v1/dictation/status says whether a dictation is recording.
/// POST /v1/dictation/insert: another app adds text or an image after the newest words of the dictation
/// being recorded, the way ⇧⌘V adds the clipboard. Images go in as file paths.
/// The body is JSON with any of `text`, `imagePath` and `imageBase64`, or raw image bytes with an image/* Content-Type.
struct DictationInsertAPIController: LocalAPIRouteHandler {
    struct InsertRequest: Decodable {
        let text: String?
        let imagePath: String?
        let imageBase64: String?
    }

    struct InsertResponse: Encodable {
        /// The file the transcript will point to, when an image was inserted.
        let imagePath: String?
    }

    struct StatusResponse: Encodable {
        /// True while a dictation is recording, which is when an insert is accepted.
        let recording: Bool
    }

    private var isRecording: Bool {
        let content = NotchContentState.shared
        return AppServices.shared.asr.isRunning && content.mode == .dictation && !content.isProcessing
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        // GET /v1/dictation/status
        if request.method == "GET" { return LocalAPI.json(StatusResponse(recording: self.isRecording)) }
        var text: String?
        var imagePath: String?
        var imageData: Data?
        if request.headers["content-type"]?.lowercased().hasPrefix("image/") == true {
            imageData = request.body
        } else {
            guard let body = try? LocalAPI.decoder.decode(InsertRequest.self, from: request.body) else {
                return LocalAPI.error("Send JSON with text, imagePath or imageBase64, or an image body with an image/* Content-Type.", status: 400)
            }
            text = body.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            imagePath = body.imagePath.map { ($0 as NSString).expandingTildeInPath }
            if let encoded = body.imageBase64 {
                guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                    return LocalAPI.error("imageBase64 is not valid base64.", status: 400)
                }
                imageData = decoded
            }
        }
        if text?.isEmpty == true { text = nil }
        guard text != nil || imagePath != nil || imageData != nil else {
            return LocalAPI.error("Nothing to insert.", status: 400)
        }
        if let imagePath, !imagePath.hasPrefix("/") || !FileManager.default.fileExists(atPath: imagePath) {
            return LocalAPI.error("imagePath must be an existing file's full path.", status: 400)
        }
        var png: Data?
        if let imageData {
            png = NSBitmapImageRep(data: imageData)?.representation(using: .png, properties: [:])
            guard png != nil else { return LocalAPI.error("The image could not be read.", status: 400) }
        }

        guard self.isRecording else {
            return LocalAPI.error("No dictation is recording.", status: 409)
        }
        if let png {
            do {
                imagePath = try LiveEditImagePaste.save(png)
            } catch {
                return LocalAPI.error("The image could not be saved: \(error.localizedDescription)", status: 500)
            }
        }
        if let text { LiveEditSession.shared.appendText(text) }
        if let imagePath { LiveEditSession.shared.appendScreenshot(at: imagePath) }
        return LocalAPI.json(InsertResponse(imagePath: imagePath))
    }
}
