import AVFoundation
import Foundation
import Testing
@testable import Minidisc

private final class AudioFixtureBundle: NSObject {}

/// Exercises the actual package/decoder and audio renderer, without a server or real account.
@Suite("AudioStreaming — real PCM playback", .serialized)
@MainActor
struct AudioStreamingDecoderTests {
    @Test(arguments: ["stream-cbr.mp3", "stream-vbr.mp3", "stream-aac.m4a", "stream-flac44.flac", "stream-flac96.flac"])
    func fileDurationCanCorrectCatalogMetadata(filename: String) async throws {
        try configureSession()
        let url = try #require(Bundle(for: AudioFixtureBundle.self).url(forResource: filename, withExtension: nil))
        let engine = AudioStreamingEngine()
        engine.volume = 0
        engine.play(trackID: filename, url: url, headers: [:])
        engine.setTrackDuration(3)
        defer { engine.stop() }
        try await eventually { engine.progress > 0.1 && engine.isSeekable }
        #expect(abs(engine.duration - 6) < 0.15)
        engine.setTrackDuration(9)
        #expect(abs(engine.duration - 6) < 0.15)
    }

    @Test(arguments: ["stream-cbr.mp3", "stream-vbr.mp3", "stream-aac.m4a", "stream-flac44.flac", "stream-flac96.flac"])
    func compressedFilePauseSeekAndResume(filename: String) async throws {
        try configureSession()
        let url = try #require(Bundle(for: AudioFixtureBundle.self).url(forResource: filename, withExtension: nil))
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        engine.play(trackID: filename, url: url, headers: [:])
        defer { engine.stop() }
        try await eventually { engine.progress > 0.1 && engine.isSeekable }
        engine.pause()
        #expect(await engine.seek(to: 3))
        let position = engine.progress
        #expect(position >= 3 && position < 3.6)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(engine.progress - position) < 0.1)
        engine.resume()
        try await eventually { engine.progress > position + 0.15 }
        #expect(observer.errors.isEmpty)
    }

    @Test func localFilePauseSeekResumeAndReset() async throws {
        try configureSession()
        let url = try makeWAV(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        let first = engine.play(trackID: "local", url: url, headers: [:])
        defer { engine.stop() }
        try await eventually { engine.progress > 0.15 && engine.isSeekable }
        engine.pause()
        let paused = engine.progress
        try await Task.sleep(for: .milliseconds(120))
        #expect(abs(engine.progress - paused) < 0.1)
        #expect(await engine.seek(to: 3))
        let sought = engine.progress
        #expect(sought >= 3 && sought < 3.5)
        try await Task.sleep(for: .milliseconds(120))
        #expect(abs(engine.progress - sought) < 0.1)
        engine.resume()
        try await eventually { engine.progress > sought + 0.1 }
        engine.resetAfterMediaServicesReset()
        #expect(engine.isReady)
        let second = engine.play(trackID: "local", url: url, headers: [:])
        #expect(second != first)
        try await eventually { engine.progress > 0.1 }
        #expect(observer.errors.isEmpty)
    }

    @Test func nativeQueueFinishesBothCopiesOfTheSameFile() async throws {
        try configureSession()
        let url = try makeWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        let first = engine.play(trackID: "repeat", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "repeat", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        try await eventually { observer.ends.count >= 1 }
        let transition = try #require(observer.ends.first)
        let promoted = try #require(transition.promotedPlayback)
        #expect(transition.endedPlaybackToken == first)
        #expect(transition.endedPosition > 0.8)
        #expect(promoted.playbackToken != first)
        #expect(engine.play(trackID: "repeat", url: url, headers: [:]) == promoted.playbackToken)
        try await eventually { observer.ends.count == 2 }
        #expect(observer.ends.last?.endedPlaybackToken == promoted.playbackToken)
        #expect(observer.ends.last?.promotedPlayback == nil)
        #expect(observer.errors.isEmpty)
    }

    @Test func seekingRequeuesThePreparedNextTrack() async throws {
        try configureSession()
        let url = try makeWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        engine.play(trackID: "first", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "second", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        try await eventually { engine.progress > 0.1 }
        #expect(await engine.seek(to: 1.5))
        try await eventually { !observer.ends.isEmpty }
        #expect(observer.ends.first?.promotedPlayback?.trackID == "second")
        #expect(observer.errors.isEmpty)
    }

    @Test(arguments: [false, true])
    func manualNextAfterSeeksStartsTheQueuedFileAtZero(paused: Bool) async throws {
        try configureSession()
        let firstURL = try makeWAV(seconds: 12)
        let nextURL = try #require(Bundle(for: AudioFixtureBundle.self).url(
            forResource: "stream-aac.m4a", withExtension: nil
        ))
        defer { try? FileManager.default.removeItem(at: firstURL) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        let first = engine.play(trackID: "first", url: firstURL, headers: [:])
        defer { engine.stop() }
        try await eventually { engine.progress > 0.1 && engine.isSeekable }
        for target in [8.0, 1.0, 7.0, 8.5] { try #require(await engine.seek(to: target)) }
        engine.preloadNext(trackID: "second", url: nextURL, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        // The local entry fits entirely in the 20-second buffer and leaves the upcoming queue.
        try await Task.sleep(for: .milliseconds(400))
        if paused { engine.pause() }
        let next = engine.play(trackID: "second", url: nextURL, headers: [:])
        #expect(next != first)
        try #require(engine.progress < 0.5, "Manual Next retained the outgoing clock: \(engine.progress)")
        try await eventually { engine.progress > 0.1 && engine.isSeekable }
        #expect(abs(engine.duration - 6) < 0.15)
        engine.pause()
        try #require(await engine.seek(to: 0))
        #expect(engine.progress < 0.5)
        engine.resume()
        try await eventually { engine.progress > 0.2 }
        #expect(observer.ends.isEmpty)
        #expect(observer.errors.isEmpty)
        try #require(await engine.seek(to: engine.duration))
        try await eventually { observer.ends.count == 1 }
        #expect(observer.ends.first?.endedPlaybackToken == next)
        #expect(observer.ends.first?.promotedPlayback == nil)
    }

    @Test func cancellingANativeQueueRestoresPausedAudioWithoutTheCancelledSong() async throws {
        try configureSession()
        let url = try makeWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        let token = engine.play(trackID: "first", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "cancelled", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        try await eventually { engine.progress > 0.2 }
        engine.pause()
        let position = engine.progress
        engine.cancelPreload()
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(engine.progress - position) < 0.15)
        #expect(observer.ends.isEmpty)
        engine.resume()
        try await eventually { !observer.ends.isEmpty }
        #expect(observer.ends.first?.endedPlaybackToken == token)
        #expect(observer.ends.first?.promotedPlayback == nil)
        #expect(observer.errors.isEmpty)
    }

    @Test func realCrossfadePromotesAnAlreadyAdvancingSecondDecoder() async throws {
        try configureSession()
        let url = try makeWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        engine.play(trackID: "first", url: url, headers: [:])
        engine.setTrackDuration(3)
        defer { engine.stop() }
        engine.preloadNext(trackID: "second", url: url, headers: [:], crossfadeDuration: 0.8, replayGainDB: -3)
        try await eventually { !observer.ends.isEmpty }
        let promoted = try #require(observer.ends.first?.promotedPlayback)
        #expect(promoted.trackID == "second")
        #expect(promoted.position > 0.1)
        #expect(promoted.audibleDuration > 0.1)
        #expect(engine.play(trackID: "second", url: url, headers: [:]) == promoted.playbackToken)
        #expect(observer.errors.isEmpty)
    }

    @Test(arguments: [false, true])
    func seekingToTheEndProducesOneNaturalBoundary(paused: Bool) async throws {
        try configureSession()
        let url = try makeWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioStreamingEngine()
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0
        engine.play(trackID: "first", url: url, headers: [:])
        defer { engine.stop() }
        try await eventually { engine.progress > 0.1 }
        if paused { engine.pause() }
        #expect(await engine.seek(to: 3))
        if paused {
            #expect(observer.ends.isEmpty)
            #expect(engine.progress > 2.9)
            engine.resume()
        }
        try await eventually { observer.ends.count == 1 }
        #expect(observer.errors.isEmpty)
    }

    private func configureSession() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    private func makeWAV(seconds: Int) throws -> URL {
        let sampleRate: UInt32 = 44_100
        let byteCount = sampleRate * UInt32(seconds) * 4
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16))
        append(UInt16(1)); append(UInt16(2)); append(sampleRate)
        append(sampleRate * 4); append(UInt16(4)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(byteCount)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioStreaming-\(UUID()).wav")
        try data.write(to: url)
        return url
    }
}
