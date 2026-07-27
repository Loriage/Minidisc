import Accelerate
import AVFoundation
import Foundation
import OSLog

/// Silence to skip at the edges of a track so consecutive album tracks butt together cleanly.
nonisolated struct GaplessTrim: Sendable, Equatable {
    /// Seconds of silence at the start, skipped by seeking before the deck starts.
    let leadIn: Double
    /// Seconds of silence at the end, cut with `forwardPlaybackEndTime`.
    let leadOut: Double

    static let none = GaplessTrim(leadIn: 0, leadOut: 0)
    var isEmpty: Bool { leadIn <= 0 && leadOut <= 0 }
}

/// Measures the digital silence at each end of a decoded track.
///
/// Lossy encoders pad both ends — MP3 typically ~1100 samples of delay, AAC ~2100 — and AVFoundation
/// only strips that automatically for some containers. Whatever it leaves behind is played as silence
/// at the seam. Rather than parse LAME/Xing and iTunSMPB per format, this measures the decoded audio,
/// which is format-agnostic and catches production silence too (a track mastered with a quiet tail).
///
/// Deliberately conservative: only true digital silence counts, and the trim is capped. A wrong
/// measurement here clips music, which is far worse than the gap it was meant to remove.
nonisolated enum GaplessTrimAnalyzer {
    /// Peak below this is silence — about -60 dBFS, low enough that a fade-out's tail is NOT trimmed.
    private static let silenceThreshold: Float = 0.001
    /// Never cut more than this from either end, whatever the measurement says.
    private static let maxTrimSeconds = 1.5
    /// How much of each end to inspect. Beyond this we stop looking and report no trim.
    private static let windowSeconds = 2.0

    /// Runs the decode off the caller's executor. Returns `.none` for anything it cannot read.
    static func measure(url: URL) async -> GaplessTrim {
        await Task.detached(priority: .utility) {
            measureSync(url: url)
        }.value
    }

    private static func measureSync(url: URL) -> GaplessTrim {
        guard let file = try? AVAudioFile(forReading: url) else { return .none }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return .none }

        let windowFrames = AVAudioFrameCount(min(Double(file.length), sampleRate * windowSeconds))
        guard windowFrames > 0,
              let head = read(file: file, at: 0, frames: windowFrames),
              let tail = read(
                  file: file,
                  at: max(0, file.length - AVAudioFramePosition(windowFrames)),
                  frames: windowFrames
              )
        else { return .none }

        let leadInFrames = leadingSilentFrames(in: head)
        let leadOutFrames = trailingSilentFrames(in: tail)
        return GaplessTrim(
            leadIn: min(Double(leadInFrames) / sampleRate, maxTrimSeconds),
            leadOut: min(Double(leadOutFrames) / sampleRate, maxTrimSeconds)
        )
    }

    private static func read(
        file: AVAudioFile,
        at position: AVAudioFramePosition,
        frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return nil
        }
        file.framePosition = position
        do { try file.read(into: buffer, frameCount: frames) } catch { return nil }
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// Frames from the buffer's start until the first sample above the threshold, on any channel.
    private static func leadingSilentFrames(in buffer: AVAudioPCMBuffer) -> Int {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        var firstAudible = count
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<min(firstAudible, count) where abs(samples[frame]) > silenceThreshold {
                firstAudible = frame
                break
            }
        }
        return firstAudible == count ? 0 : firstAudible
    }

    /// Frames from the last sample above the threshold to the buffer's end, on any channel.
    private static func trailingSilentFrames(in buffer: AVAudioPCMBuffer) -> Int {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        var lastAudible = -1
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            var frame = count - 1
            while frame > lastAudible {
                if abs(samples[frame]) > silenceThreshold {
                    lastAudible = frame
                    break
                }
                frame -= 1
            }
        }
        return lastAudible < 0 ? 0 : count - 1 - lastAudible
    }
}
