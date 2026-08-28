import AVFoundation
import Foundation
import Testing
@testable import Minidisc

@Suite("GaplessTrimAnalyzer")
struct GaplessTrimAnalyzerTests {
    @Test func measuresSilentEdgesWithoutClippingSignal() async throws {
        let sampleRate = 44_100.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gapless-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frameCount = AVAudioFrameCount(sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        let audibleStart = Int(sampleRate * 0.1)
        let audibleEnd = Int(sampleRate * 0.8)
        for frame in audibleStart..<audibleEnd {
            samples[frame] = 0.25
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let trim = await GaplessTrimAnalyzer.measure(url: url)
        #expect(abs(trim.leadIn - 0.1) < 0.01)
        #expect(abs(trim.leadOut - 0.2) < 0.01)
    }

    @Test func unreadableFileIsNeverTrimmed() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).caf")
        #expect(await GaplessTrimAnalyzer.measure(url: missing) == .none)
    }

    @Test func fullySilentFileIsNeverTrimmed() async throws {
        let sampleRate = 44_100.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gapless-silent-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate)
            )
        )
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        #expect(await GaplessTrimAnalyzer.measure(url: url) == .none)
    }

    @Test func trimIsCappedBeforeItCanClipLongSilence() async throws {
        let sampleRate = 44_100.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gapless-cap-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        // Keep the audible sample inside both two-second inspection windows while leaving
        // more than the 1.5-second safety cap on either side.
        let frameCount = AVAudioFrameCount(sampleRate * 3.5)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        let signalStart = Int(sampleRate * 1.75)
        let signalEnd = signalStart + 100
        for frame in signalStart..<signalEnd {
            samples[frame] = 0.25
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)

        let trim = await GaplessTrimAnalyzer.measure(url: url)
        #expect(abs(trim.leadIn - 1.5) < 0.001)
        #expect(abs(trim.leadOut - 1.5) < 0.001)
    }
}
