import Accelerate
import Foundation
#if arch(arm64)
import CoreML
import FluidAudio
#endif

/// Silences audio that isn't the user's own voice before the final transcription, so a TV, music or
/// someone across the room doesn't end up in the text. Removed audio becomes silence instead of being
/// cut out, so word timings (Shift+Enter line breaks) keep their positions. History keeps the raw
/// recording, so a saved dictation can be replayed through a retuned filter.
nonisolated enum DictationVoiceFilter {
    /// Returns `samples[start...]` filtered. The loudness reference comes from all of `samples`, and the
    /// voice match also reads the 4 s before `start`, so the live preview can filter just its newest audio
    /// at a flat cost however long the recording gets. `live` skips logging and the unfiltered fallback:
    /// a few seconds with nothing of the user in them is normal mid-dictation.
    static func apply(
        _ samples: [Float],
        from start: Int = 0,
        gate: Bool,
        voiceProfile: DictationVoiceProfile?,
        live: Bool = false
    ) async -> [Float] {
        let contextStart = voiceProfile == nil ? start : max(0, start - DictationVoiceMatcher.windowSamples)
        var output: [Float]
        if gate {
            let result = DictationNearFieldGate.apply(samples, from: contextStart)
            output = result.samples
            if !live { DebugLogger.shared.info(result.summary, source: "VoiceFilter") }
        } else {
            output = Array(samples[contextStart...])
        }
        if let voiceProfile {
            do {
                output = try await DictationVoiceMatcher.shared.keepOnlyVoice(of: voiceProfile, in: output, live: live)
            } catch where !live {
                DebugLogger.shared.error("voice_match skipped: \(error.localizedDescription)", source: "VoiceFilter")
            } catch {}
        }
        return Array(output[(start - contextStart)...])
    }
}

/// Silences audio far quieter than the user's own voice. A near microphone hears the user well above a
/// TV or a person across the room (the meeting pipeline measured 22 dB), and Parakeet otherwise
/// transcribes that audio in the user's pauses. The reference is the recording's own loud end, so the
/// rule holds across microphones and input gain. A recording of nothing but distant audio anchors on
/// that audio and passes through.
nonisolated enum DictationNearFieldGate {
    static let frameSamples = 320 // 20 ms at 16 kHz
    /// Audio this far below the reference is removed. Soft consonants sit lower, but always next to
    /// louder vowels, inside the lead and hold below.
    static let rejectionDepthDB: Float = 20
    /// Nothing this quiet is intelligible near-field speech on any hardware.
    static let absoluteFloorRMS: Float = 0.0015
    /// The reference is the level the loudest half second reaches: a cough or a door can't set it,
    /// and it is still the user's voice when they spoke briefly in a long recording.
    static let referenceFrames = 25
    static let leadFrames = 5 // keep 100 ms before the voice
    static let holdFrames = 15 // and 300 ms after it
    static let rampSamples = 160 // 10 ms fades, no clicks

    struct Result {
        var samples: [Float]
        var referenceRMS: Float?
        var keptFraction: Double

        var summary: String {
            guard let referenceRMS else { return "near_field_gate skipped=too_short" }
            return String(
                format: "near_field_gate referenceDb=%.1f thresholdDb=%.1f kept=%.0f%%",
                20 * log10(max(referenceRMS, 1e-9)),
                20 * log10(max(referenceRMS, 1e-9)) - DictationNearFieldGate.rejectionDepthDB,
                self.keptFraction * 100
            )
        }
    }

    /// Gates `samples[start...]`, with the reference taken from all of `samples`.
    static func apply(_ samples: [Float], from start: Int = 0) -> Result {
        let frameCount = (samples.count + self.frameSamples - 1) / self.frameSamples
        guard frameCount >= self.referenceFrames else {
            return Result(samples: Array(samples[start...]), referenceRMS: nil, keptFraction: 1)
        }
        var levels = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                let start = frame * self.frameSamples
                let length = min(self.frameSamples, samples.count - start)
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &levels[frame], vDSP_Length(length))
            }
        }
        let reference = levels.sorted(by: >)[self.referenceFrames - 1]
        guard reference >= self.absoluteFloorRMS else {
            return Result(samples: Array(samples[start...]), referenceRMS: reference, keptFraction: 1)
        }
        let threshold = max(self.absoluteFloorRMS, reference * pow(10, -self.rejectionDepthDB / 20))
        var open = [Bool](repeating: false, count: frameCount)
        for frame in 0..<frameCount where levels[frame] >= threshold {
            for neighbor in max(0, frame - self.leadFrames)...min(frameCount - 1, frame + self.holdFrames) {
                open[neighbor] = true
            }
        }
        var output = Array(samples[start...])
        let step = 1 / Float(self.rampSamples)
        var gain: Float = start < samples.count && open[start / self.frameSamples] ? 1 : 0
        for index in output.indices {
            let target: Float = open[(start + index) / self.frameSamples] ? 1 : 0
            gain = target > gain ? min(target, gain + step) : max(target, gain - step)
            output[index] *= gain
        }
        let kept = Double(open.filter { $0 }.count) / Double(frameCount)
        return Result(samples: output, referenceRMS: reference, keptFraction: kept)
    }
}

/// The user's voice fingerprint: the mean WeSpeaker embedding of a recording of them reading aloud.
/// Stays on this Mac.
nonisolated struct DictationVoiceProfile: Codable, Sendable {
    var embedding: [Float]
    var speechSeconds: Double
    var createdAt: Date

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidVoice/voice-profile.json")
    }

    static func load() -> DictationVoiceProfile? {
        guard let data = try? Data(contentsOf: self.fileURL),
              let profile = try? JSONDecoder().decode(Self.self, from: data),
              profile.embedding.count == 256
        else { return nil }
        return profile
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: self.fileURL)
    }
}

enum DictationVoiceFilterError: LocalizedError {
    case notEnoughSpeech
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notEnoughSpeech: "Not enough speech to learn your voice. Read for at least 20 seconds."
        case .unsupported: "Voice matching needs an Apple silicon Mac."
        }
    }
}

/// Keeps only speech that sounds like the enrolled voice. Each stretch of speech is fingerprinted with
/// the WeSpeaker model the meeting pipeline already uses and compared with the voice profile.
actor DictationVoiceMatcher {
    static let shared = DictationVoiceMatcher()

    /// Cosine distance past which a window counts as someone else. A starting value to tune against the
    /// logged distances: the same voice across sessions usually lands around 0.2–0.5, other voices 0.7–1.0.
    static let rejectDistance: Float = 0.65
    /// Shorter windows give unreliable fingerprints and are kept.
    static let minimumJudgedSamples = 16_000
    /// Long speech is judged in windows of at most 4 s, so a TV line right after the user's sentence can
    /// go without taking the sentence with it.
    static let windowSamples = 64_000
    static let minimumEnrollmentWindows = 4
    static let minimumEnrollmentWindowSamples = 24_000

    #if arch(arm64)
    private static let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.25,
        minSilenceDuration: 0.4,
        speechPadding: 0.2
    )

    private var vad: VadManager?
    private var extractor: EmbeddingExtractor?
    private var mask: [Float] = []

    func prepare() async throws {
        if self.vad == nil {
            self.vad = try await VadManager()
        }
        guard self.extractor == nil else { return }
        let models = try await DownloadUtils.loadModels(
            .diarizer,
            modelNames: [ModelNames.Diarizer.embeddingFile],
            directory: DiarizerModels.defaultModelsDirectory().deletingLastPathComponent(),
            computeUnits: .cpuAndNeuralEngine
        )
        guard let model = models[ModelNames.Diarizer.embeddingFile],
              let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?
              .multiArrayConstraint?.shape.last?.intValue,
              (1...4096).contains(maskFrames)
        else { throw DictationVoiceFilterError.unsupported }
        self.mask = [Float](repeating: 1, count: maskFrames)
        self.extractor = EmbeddingExtractor(embeddingModel: model)
    }

    func keepOnlyVoice(of profile: DictationVoiceProfile, in samples: [Float], live: Bool) async throws -> [Float] {
        try await self.prepare()
        let windows = try await self.speechWindows(samples)
        var output = [Float](repeating: 0, count: samples.count)
        var matched = 0
        var rejected = 0
        var notes: [String] = []
        for window in windows {
            var distance: Float?
            if window.count >= Self.minimumJudgedSamples, let embedding = try self.embedding(samples[window]) {
                distance = Self.distance(embedding, profile.embedding)
            }
            let keep = distance.map { $0 <= Self.rejectDistance } ?? true
            if distance != nil {
                if keep { matched += 1 } else { rejected += 1 }
            }
            if keep {
                output.replaceSubrange(window, with: samples[window])
            }
            notes.append(String(
                format: "%.1fs+%.1fs:%@%@",
                Double(window.lowerBound) / 16_000,
                Double(window.count) / 16_000,
                distance.map { String(format: "%.2f", $0) } ?? "short",
                keep ? "" : "x"
            ))
        }
        if live { return output }
        let summary = "voice_match windows=\(windows.count) matched=\(matched) rejected=\(rejected) [\(notes.joined(separator: " "))]"
        // A profile that matches nothing is more likely a different mic or a hoarse voice than a dictation
        // with no user in it, and silence would lose the dictation.
        guard !windows.isEmpty, matched > 0 || rejected == 0 else {
            DebugLogger.shared.info("\(summary) fallback=unfiltered", source: "VoiceFilter")
            return samples
        }
        DebugLogger.shared.info(summary, source: "VoiceFilter")
        return output
    }

    /// Builds a voice profile from a recording of the user reading aloud in a quiet room.
    func enroll(_ samples: [Float]) async throws -> DictationVoiceProfile {
        try await self.prepare()
        let windows = try await self.speechWindows(samples).filter { $0.count >= Self.minimumEnrollmentWindowSamples }
        let embeddings = try windows.compactMap { try self.embedding(samples[$0]) }
        guard embeddings.count >= Self.minimumEnrollmentWindows,
              let centroid = Self.normalized(embeddings.reduce([Float](repeating: 0, count: 256)) { vDSP.add($0, $1) })
        else { throw DictationVoiceFilterError.notEnoughSpeech }
        let spread = embeddings.map { String(format: "%.2f", Self.distance($0, centroid)) }
        DebugLogger.shared.info("voice_enroll windows=\(embeddings.count) distances=[\(spread.joined(separator: " "))]", source: "VoiceFilter")
        return DictationVoiceProfile(
            embedding: centroid,
            speechSeconds: Double(windows.reduce(0) { $0 + $1.count }) / 16_000,
            createdAt: Date()
        )
    }

    private func speechWindows(_ samples: [Float]) async throws -> [Range<Int>] {
        guard let vad = self.vad else { return [] }
        let segments = try await vad.segmentSpeech(samples, config: Self.segmentation)
        return segments.flatMap { segment -> [Range<Int>] in
            let start = max(0, segment.startSample(sampleRate: 16_000))
            let end = min(samples.count, segment.endSample(sampleRate: 16_000))
            guard end > start else { return [] }
            let pieces = (end - start + Self.windowSamples - 1) / Self.windowSamples
            let size = (end - start + pieces - 1) / pieces
            return stride(from: start, to: end, by: size).map { $0..<min($0 + size, end) }
        }
    }

    private func embedding(_ clip: ArraySlice<Float>) throws -> [Float]? {
        guard let extractor = self.extractor else { return nil }
        let output = try extractor.getEmbeddings(audio: Array(clip), masks: [self.mask])
        guard let raw = output.first, raw.count == 256, raw.allSatisfy(\.isFinite) else { return nil }
        return Self.normalized(raw)
    }
    #else
    func prepare() async throws { throw DictationVoiceFilterError.unsupported }

    func keepOnlyVoice(of profile: DictationVoiceProfile, in samples: [Float], live: Bool) async throws -> [Float] {
        throw DictationVoiceFilterError.unsupported
    }

    func enroll(_ samples: [Float]) async throws -> DictationVoiceProfile {
        throw DictationVoiceFilterError.unsupported
    }
    #endif

    static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = sqrt(vDSP.sumOfSquares(vector))
        guard norm > 0, norm.isFinite else { return nil }
        return vDSP.divide(vector, norm)
    }

    /// Both vectors are unit length.
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        1 - vDSP.dot(lhs, rhs)
    }
}
