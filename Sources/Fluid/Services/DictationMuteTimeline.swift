import Foundation

/// Acquisition-time exclusions, accessed under AudioCapturePipeline's capture lock.
/// Retaining closed intervals rejects audio delivered after the key has been released.
nonisolated struct DictationMuteTimeline {
    private struct Interval {
        let start: UInt64
        var end: UInt64?
    }

    private var intervals: [Interval] = []
    private(set) var isMuted = false
    var hasExclusions: Bool {
        !self.intervals.isEmpty
    }

    mutating func setMuted(_ muted: Bool, at hostTime: UInt64) {
        guard muted != self.isMuted else { return }
        self.isMuted = muted
        if muted {
            self.intervals.append(Interval(start: hostTime))
        } else if let last = self.intervals.indices.last {
            self.intervals[last].end = max(hostTime, self.intervals[last].start)
        }
    }

    func audibleRanges(
        in range: Range<Int>,
        packetHostTime: UInt64,
        sampleRate: Double,
        hostTicksPerSecond: Double
    ) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        guard !self.intervals.isEmpty else { return [range] }
        // Once a session has muted audio, an untimestamped packet cannot safely be
        // attributed to either side of a mute boundary. Do not leak it into ASR.
        guard packetHostTime > 0 else { return [] }
        var cursor = range.lowerBound
        var result: [Range<Int>] = []
        for interval in self.intervals {
            let start = (Double(interval.start) - Double(packetHostTime)) * sampleRate / hostTicksPerSecond
            let end = interval.end.map { (Double($0) - Double(packetHostTime)) * sampleRate / hostTicksPerSecond }
                ?? Double(range.upperBound)
            let lower = Int(max(Double(range.lowerBound), min(Double(range.upperBound), floor(start))))
            let upper = Int(max(Double(range.lowerBound), min(Double(range.upperBound), ceil(end))))
            if lower > cursor {
                result.append(cursor..<lower)
            }
            cursor = max(cursor, upper)
        }
        if cursor < range.upperBound {
            result.append(cursor..<range.upperBound)
        }
        return result
    }
}

/// Live Edit typing hold, accessed under AudioCapturePipeline's capture lock. Audio recorded after a key
/// press waits for `window`: another key press inside it drops that audio, and without one it is kept
/// whole, so speech that starts right after the last key loses nothing.
nonisolated struct DictationTypingHold {
    private var deadline: UInt64?
    private var held: [Float] = []
    private var dropped = false

    mutating func keyPressed(at hostTime: UInt64, windowTicks: UInt64) {
        if !self.held.isEmpty { self.dropped = true }
        self.held.removeAll(keepingCapacity: true)
        self.deadline = hostTime &+ windowTicks
    }

    /// Returns the 16 kHz samples to commit now, for a packet that starts at `hostTime`.
    mutating func route(_ samples: [Float], at hostTime: UInt64) -> [Float] {
        guard let deadline else { return samples }
        guard hostTime >= deadline else {
            self.held += samples
            return []
        }
        return self.release() + samples
    }

    /// Ends the hold and returns the audio it was holding; a stop keeps the newest words.
    mutating func release() -> [Float] {
        defer {
            self.deadline = nil
            self.held = []
            self.dropped = false
        }
        // A short gap where audio was dropped, so the words on each side stay apart.
        return self.dropped && !self.held.isEmpty ? [Float](repeating: 0, count: 1600) + self.held : self.held
    }
}
