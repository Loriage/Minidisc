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
}
