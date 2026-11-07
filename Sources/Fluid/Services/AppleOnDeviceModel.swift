import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model. Used only to retry AI enhancement when the cloud
/// provider cannot be reached, never as a selectable provider.
enum AppleOnDeviceModel {
    static let displayName = "Apple on-device"

    /// Why the model cannot run on this Mac, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings to use this."
            case .unavailable(.modelNotReady):
                return "Apple's model is still downloading."
            default:
                return "This Mac can't run Apple's on-device model."
            }
        }
        #endif
        return "Requires macOS 26 or later."
    }

    /// Returns nil when the model cannot run here, so callers keep their original error.
    static func enhance(systemPrompt: String, userContent: String) async throws -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            // Cleanup rewrites user text, so use the guardrails Apple provides for transformations.
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: systemPrompt.isEmpty ? nil : systemPrompt)
            let response = try await session.respond(to: userContent, options: GenerationOptions(temperature: 0.2))
            return response.content
        }
        #endif
        return nil
    }
}
