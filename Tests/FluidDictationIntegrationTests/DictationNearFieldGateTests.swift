@testable import FluidVoice_Debug
import XCTest

/// Levels from the meeting pipeline's real speakerphone session: the user at 0.0287 RMS, a TV at 0.0023.
final class DictationNearFieldGateTests: XCTestCase {
    private func tone(rms: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { rms * sqrt(2) * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    func testSilencesDistantAudioBetweenTheUsersWords() {
        let voice = self.tone(rms: 0.0287, seconds: 1)
        let tv = self.tone(rms: 0.0023, seconds: 1)
        let input = tv + voice + tv + voice + tv
        let output = DictationNearFieldGate.apply(input).samples

        XCTAssertEqual(output[24_000], input[24_000], "the user's voice passes untouched")
        XCTAssertEqual(output[8_000], 0, "TV before the user speaks is silenced")
        XCTAssertEqual(output[44_000], 0, "TV between the user's sentences is silenced")
        XCTAssertNotEqual(output[34_000], 0, "the hold keeps the 300 ms after the voice")
    }

    /// The live preview gates only its newest audio; it must match what gating the whole recording gives.
    func testGatingFromAnOffsetMatchesTheTailOfTheWholeRecording() {
        let voice = self.tone(rms: 0.0287, seconds: 1)
        let tv = self.tone(rms: 0.0023, seconds: 1)
        let input = tv + voice + tv + voice + tv
        let whole = DictationNearFieldGate.apply(input).samples
        for start in [0, 1, 16_000, 33_123, input.count - 1] {
            XCTAssertEqual(DictationNearFieldGate.apply(input, from: start).samples, Array(whole[start...]), "from \(start)")
        }
    }

    func testLeavesARecordingOfOnlyDistantAudioAlone() {
        let input = self.tone(rms: 0.0023, seconds: 3)
        XCTAssertEqual(DictationNearFieldGate.apply(input).samples, input)
    }
}
