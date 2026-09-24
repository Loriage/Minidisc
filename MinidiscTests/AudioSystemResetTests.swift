import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Minidisc

private nonisolated final class ResetTestPlayer: AVQueuePlayer, @unchecked Sendable {
    private let forcedFailure = Mutex(false)
    private let itemClears = Mutex(0)
    var clearedItemCount: Int { itemClears.withLock { $0 } }

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        if item == nil { itemClears.withLock { $0 += 1 } }
        super.replaceCurrentItem(with: item)
    }

    override func removeAllItems() {
        itemClears.withLock { $0 += 1 }
        super.removeAllItems()
    }

    func failPermanently() { forcedFailure.withLock { $0 = true } }

    override var status: AVPlayer.Status {
        forcedFailure.withLock { $0 } ? .failed : super.status
    }
}

private nonisolated final class ResetTestPlayerFactory: Sendable {
    private let storage = Mutex<[ResetTestPlayer]>([])

    var players: [ResetTestPlayer] { storage.withLock { $0 } }

    func makePlayer() -> AVQueuePlayer {
        let player = ResetTestPlayer()
        storage.withLock { $0.append(player) }
        return player
    }
}

@MainActor
@Suite("Audio system reset", .serialized)
struct AudioSystemResetTests {
    @Test func classifiesMediaServicesResetWithoutConfusingNetworkErrors() {
        let reset = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.mediaServicesWereReset.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -17221)]
        )
        #expect(AudioEngineFailure(error: reset).isMediaServicesReset)
        #expect(AudioEngineFailure(error: NSError(
            domain: NSURLErrorDomain, code: -1, userInfo: [NSUnderlyingErrorKey: reset]
        )).isMediaServicesReset)
        #expect(!AudioEngineFailure(error: URLError(.networkConnectionLost)).isMediaServicesReset)
        #expect(!AudioEngineFailure(error: NSError(
            domain: NSURLErrorDomain, code: AVError.Code.mediaServicesWereReset.rawValue
        )).isMediaServicesReset)
        #expect(!AudioEngineFailure(error: nil).isMediaServicesReset)
    }

    @Test func diagnosticsFollowQueuedItemsAndIgnoreRetiredItemNotifications() throws {
        let factory = ResetTestPlayerFactory()
        let diagnostics = PlaybackDiagnostics()
        let engine = AVPlayerEngine(diagnostics: diagnostics, playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.setAirPlayActive(true)
        let first = engine.play(trackID: "PRIVATE_FIRST", url: url, headers: [:])
        let oldItem = try #require(factory.players[0].currentItem)
        engine.preloadNext(trackID: "PRIVATE_NEXT", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        let queuedItem = try #require(factory.players[0].items().last)
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: queuedItem)
        engine.resetAfterMediaServicesReset()
        let second = engine.play(trackID: "PRIVATE_SECOND", url: url, headers: [:])
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: oldItem)
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: factory.players[2].currentItem)

        let report = diagnostics.makeReport(context: .init(
            appVersion: "test", appBuild: "0", operatingSystem: "test", playbackStatus: .loading,
            isPlaybackAvailable: true, networkPath: nil, connectionVersion: nil
        ))
        #expect(report.contains("trigger=preload item=\(first.rawValue + 1) role=queued"))
        #expect(report.contains("trigger=stalled item=\(first.rawValue + 1) role=queued"))
        #expect(report.contains("trigger=reset item=\(first.rawValue)"))
        #expect(!report.contains("trigger=stalled item=\(first.rawValue) role=active"))
        #expect(report.contains("trigger=stalled item=\(second.rawValue) role=active"))
        #expect(!report.contains("PRIVATE_"))
        #expect(!report.contains(url.absoluteString))
    }

    @Test func resetReplacesBothPhysicalPlayersAndDiscardsTheirItems() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.volume = 0.4
        engine.applyReplayGain(dB: -6)
        let firstToken = engine.play(trackID: "first", url: url, headers: [:])
        engine.preloadNext(
            trackID: "next", url: url, headers: [:],
            crossfadeDuration: 5, replayGainDB: -3
        )
        let originals = factory.players
        #expect(originals.count == 2)
        #expect(originals.allSatisfy { $0.currentItem != nil })

        engine.resetAfterMediaServicesReset()
        let replacements = Array(factory.players.suffix(2))
        #expect(factory.players.count == 4)
        #expect(replacements.allSatisfy { candidate in !originals.contains { $0 === candidate } })
        #expect(originals.allSatisfy { $0.currentItem == nil })
        #expect(replacements.allSatisfy { $0.currentItem == nil })
        #expect(engine.isReady)
        #expect(engine.volume == 0.4)
        #expect(replacements.allSatisfy { $0.automaticallyWaitsToMinimizeStalling && $0.actionAtItemEnd == .pause })

        // Reloading even the preloaded song must create a new token, never adopt the old deck.
        let newToken = engine.play(trackID: "next", url: url, headers: [:])
        #expect(newToken.rawValue > firstToken.rawValue + 1)
        #expect(replacements[0].currentItem != nil)
        #expect(abs(replacements[0].volume - 0.4 * pow(10, -6.0 / 20)) < 0.001)
        #expect(factory.players.count == 4)
    }

    @Test
    func nextDiscardsATerminalPlayerBeforeItsFailureCallbackArrives() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        let oldToken = engine.play(trackID: "first", url: url, headers: [:])
        factory.players[0].failPermanently()

        let nextToken = engine.play(trackID: "second", url: url, headers: [:])
        #expect(factory.players.count == 4)
        #expect(factory.players.prefix(2).allSatisfy { $0.currentItem == nil })
        #expect(factory.players[2].currentItem != nil)
        #expect(nextToken.rawValue > oldToken.rawValue)
        #expect(!engine.isReady)
    }

    @Test(arguments: [0.0, 5.0])
    func airPlayQueuesOnOnePhysicalPlayerAndManualNextAdoptsItem(overlap: Double) throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.setAirPlayActive(true)
        let first = engine.play(trackID: "first", url: url, headers: [:])
        let active = factory.players[0]
        let standby = factory.players[1]
        let clears = active.clearedItemCount
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: overlap, replayGainDB: 0)
        #expect(standby.currentItem == nil)
        #expect(active.items().count == 2)
        let queued = try #require(active.items().last)
        standby.failPermanently()
        let next = engine.play(trackID: "next", url: url, headers: [:])
        #expect(next != first)
        #expect(factory.players.count == 2)
        #expect(active.currentItem === queued)
        #expect(active.items().count == 1)
        #expect(active.clearedItemCount == clears)
        #expect(standby.currentItem == nil)
    }

    @Test func connectingAirPlayDiscardsExistingCrossfadeStandby() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.play(trackID: "first", url: url, headers: [:])
        engine.setTrackDuration(120)
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 5, replayGainDB: 0)
        let activeItem = try #require(factory.players[0].currentItem)
        #expect(factory.players[1].currentItem != nil)

        engine.setAirPlayActive(true)
        #expect(factory.players[0].currentItem === activeItem)
        #expect(factory.players[1].currentItem == nil)
        #expect(!activeItem.forwardPlaybackEndTime.isValid)
        engine.setAirPlayActive(false)
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        #expect(factory.players[1].currentItem == nil)
        #expect(factory.players[0].items().count == 2)
    }

    @Test func mediaResetRetainsAirPlayTransitionMode() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.setAirPlayActive(true)
        engine.play(trackID: "first", url: url, headers: [:])
        engine.resetAfterMediaServicesReset()
        engine.play(trackID: "first", url: url, headers: [:])
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 5, replayGainDB: 0)
        #expect(factory.players.count == 4)
        #expect(factory.players[2].currentItem != nil)
        #expect(factory.players[3].currentItem == nil)
        #expect(factory.players[2].items().count == 2)
        #expect(factory.players[2].actionAtItemEnd == .advance)
    }

    @Test(arguments: [false, true])
    func queueAutomaticallyAdvancesOnceAndAdoptsThePlayingItem(airPlay: Bool) async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let events = QueueTransitionRecorder()
        engine.delegate = events
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.setAirPlayActive(airPlay)
        let token = engine.play(trackID: "first", url: url, headers: [:])
        let oldItem = try #require(factory.players[0].currentItem)
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: -6)
        let nextItem = try #require(factory.players[0].items().last)
        let deadline = ContinuousClock.now + .seconds(8)
        while events.transitions.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let transition = try #require(events.transitions.first)
        #expect(transition.endedPlaybackToken == token)
        #expect(transition.endedPosition > 0.8)
        let promoted = try #require(transition.promotedPlayback)
        #expect(promoted.trackID == "next")
        #expect(factory.players[0].currentItem === nextItem)
        #expect(factory.players[1].currentItem == nil)
        #expect(abs(factory.players[0].volume - pow(10, -6.0 / 20)) < 0.001)
        let adopted = engine.play(trackID: "next", url: url, headers: [:])
        #expect(adopted == promoted.playbackToken)
        #expect(factory.players[0].currentItem === nextItem)
        engine.pause()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: oldItem)
        #expect(events.transitions.count == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(events.transitions.count == 1)
        engine.resume()
        let endDeadline = ContinuousClock.now + .seconds(8)
        while events.transitions.count < 2, ContinuousClock.now < endDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(events.transitions.count == 2)
        #expect(events.transitions.last?.endedPlaybackToken == promoted.playbackToken)
        #expect(events.transitions.last?.promotedPlayback == nil)
        #expect(factory.players[0].currentItem === nextItem)
        #expect(engine.progress > 0.8)
    }

    @Test func airPlayCancellationAndRouteChangesRemoveOnlyUpcomingItems() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.setAirPlayActive(true)
        engine.play(trackID: "first", url: url, headers: [:])
        engine.pause()
        let current = try #require(factory.players[0].currentItem)
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        engine.cancelPreload()
        #expect(factory.players[0].items().count == 1)
        #expect(factory.players[0].currentItem === current)
        engine.preloadNext(trackID: "replacement", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        #expect(factory.players[0].items().count == 2)
        engine.setAirPlayActive(false)
        #expect(factory.players[0].items().count == 1)
        #expect(factory.players[0].currentItem === current)
        #expect(factory.players[0].actionAtItemEnd == .pause)
        engine.preloadNext(trackID: "replacement", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        #expect(factory.players[1].currentItem == nil)
        #expect(factory.players[0].items().count == 2)
        engine.stop()
        #expect(factory.players.allSatisfy { $0.items().isEmpty })
    }

    @Test func connectingAirPlayAfterLocalPromotionKeepsTheSecondPhysicalPlayer() async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let events = QueueTransitionRecorder()
        engine.delegate = events
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.play(trackID: "first", url: url, headers: [:])
        engine.preloadNext(trackID: "second", url: url, headers: [:], crossfadeDuration: 0.25, replayGainDB: 0)
        let deadline = ContinuousClock.now + .seconds(8)
        while events.transitions.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let transition = try #require(events.transitions.first)
        _ = try #require(transition.promotedPlayback)
        engine.play(trackID: "second", url: url, headers: [:])
        engine.pause()
        let second = try #require(factory.players[1].currentItem)
        engine.setAirPlayActive(true)
        engine.preloadNext(trackID: "third", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        #expect(factory.players[1].currentItem === second)
        #expect(factory.players[1].items().count == 2)
        #expect(factory.players[0].items().isEmpty)
        let third = try #require(factory.players[1].items().last)
        engine.play(trackID: "third", url: url, headers: [:])
        #expect(factory.players[1].currentItem === third)
        #expect(factory.players.count == 2)
        engine.play(trackID: "first", url: url, headers: [:])
        #expect(factory.players[1].items().count == 1)
        #expect(factory.players[1].currentItem !== third)
        #expect(factory.players[0].items().isEmpty)
    }

    @Test func crossfadeCanBeEnabledAndDisabledForTheSameUpcomingTrack() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.play(trackID: "first", url: url, headers: [:])
        engine.pause()
        let active = factory.players[0]
        let first = try #require(active.currentItem)

        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        #expect(active.items().count == 2)
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 3, replayGainDB: 0)
        #expect(active.items().count == 1)
        #expect(active.actionAtItemEnd == .pause)
        #expect(factory.players[1].currentItem != nil)
        engine.preloadNext(trackID: "next", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: -3)
        #expect(active.currentItem === first)
        #expect(active.items().count == 2)
        #expect(active.actionAtItemEnd == .advance)
        #expect(factory.players[1].currentItem == nil)
        #expect(active.rate == 0)
    }

    @Test func replacingUpcomingTrackAndSeekingKeepTheActivePlayer() async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let events = QueueTransitionRecorder()
        engine.delegate = events
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.play(trackID: "first", url: url, headers: [:])
        engine.pause()
        let active = factory.players[0]
        let first = try #require(active.currentItem)
        engine.preloadNext(trackID: "removed", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        let removed = try #require(active.items().last)
        engine.cancelPreload()
        engine.preloadNext(trackID: "replacement", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        let replacement = try #require(active.items().last)
        #expect(!active.items().contains { $0 === removed })
        #expect(active.items().count == 2)
        let deadline = ContinuousClock.now + .seconds(8)
        while first.status == .unknown, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.seek(to: 0.25))
        #expect(active.currentItem === first)
        #expect(active.items().last === replacement)
        #expect(active.rate == 0)
        let nextToken = engine.play(trackID: "replacement", url: url, headers: [:])
        #expect(active.currentItem === replacement)
        engine.pause()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first)
        #expect(events.transitions.isEmpty)
        let previousToken = engine.play(trackID: "first", url: url, headers: [:])
        #expect(previousToken != nextToken)
        #expect(active.items().count == 1)
        #expect(factory.players[1].currentItem == nil)
    }

    @Test func idleDeckFailureDoesNotInterruptSequentialPlaybackAndIsRebuiltForCrossfade() throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.play(trackID: "first", url: url, headers: [:])
        factory.players[1].failPermanently()
        engine.play(trackID: "second", url: url, headers: [:])
        engine.pause()
        let active = factory.players[0]
        let current = try #require(active.currentItem)
        #expect(factory.players.count == 2)
        engine.preloadNext(trackID: "third", url: url, headers: [:], crossfadeDuration: 5, replayGainDB: 0)
        #expect(factory.players.count == 3)
        #expect(active.currentItem === current)
        #expect(active.rate == 0)
        #expect(factory.players[2].currentItem != nil)
    }

    @Test func sequentialPlaybackPreservesSilenceAndRepeatedTrackIdentity() async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let events = QueueTransitionRecorder()
        engine.delegate = events
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        let firstToken = engine.play(trackID: "same", url: url, headers: [:])
        let first = try #require(factory.players[0].currentItem)
        engine.preloadNext(trackID: "same", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        #expect(!first.forwardPlaybackEndTime.isValid)
        let deadline = ContinuousClock.now + .seconds(8)
        while events.transitions.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let transition = try #require(events.transitions.first)
        let promoted = try #require(transition.promotedPlayback)
        #expect(transition.endedPlaybackToken == firstToken)
        #expect(transition.endedPosition > 0.9)
        #expect(promoted.playbackToken != firstToken)
        #expect(promoted.trackID == "same")
        let adopted = engine.play(trackID: "same", url: url, headers: [:])
        #expect(adopted == promoted.playbackToken)
    }

    @Test func queuedReplayGainBoostSurvivesManualPromotion() async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        engine.play(trackID: "first", url: url, headers: [:])
        engine.pause()
        engine.preloadNext(trackID: "boosted", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 6)
        let queued = try #require(factory.players[0].items().last)
        let deadline = ContinuousClock.now + .seconds(8)
        while queued.audioMix == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let mix = try #require(queued.audioMix)
        engine.play(trackID: "boosted", url: url, headers: [:])
        engine.pause()
        #expect(factory.players[0].currentItem === queued)
        #expect(queued.audioMix === mix)
        #expect(factory.players[0].volume == 1)
        #expect(factory.players[1].currentItem == nil)
    }

    @Test func failedUpcomingFileDoesNotSkipOrStopTheCurrentTrack() async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let events = QueueTransitionRecorder()
        engine.delegate = events
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        let firstToken = engine.play(trackID: "first", url: url, headers: [:])
        let missing = url.deletingLastPathComponent().appendingPathComponent("\(UUID()).wav")
        engine.preloadNext(trackID: "missing", url: missing, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        let deadline = ContinuousClock.now + .seconds(8)
        while events.transitions.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let transition = try #require(events.transitions.first)
        #expect(transition.endedPlaybackToken == firstToken)
        #expect(transition.endedPosition > 0.9)
        #expect(events.transitions.count == 1)
        let retry = engine.play(trackID: "retry", url: url, headers: [:])
        #expect(retry != firstToken)
        #expect(factory.players[0].items().count == 1)
        #expect(factory.players[1].items().isEmpty)
    }

    @Test(arguments: [kAudioFormatAppleLossless, kAudioFormatMPEG4AAC])
    func nativeQueueAdvancesAcrossDifferentFormats(formatID: AudioFormatID) async throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let events = QueueTransitionRecorder()
        engine.delegate = events
        let wav = try silentWave()
        let encoded = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        defer {
            engine.stop()
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: encoded)
        }
        do {
            let file = try AVAudioFile(forWriting: encoded, settings: [
                AVFormatIDKey: formatID,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 2
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            try file.write(from: buffer)
        }
        engine.play(trackID: "wav", url: wav, headers: [:])
        engine.preloadNext(trackID: "encoded", url: encoded, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        let deadline = ContinuousClock.now + .seconds(8)
        while events.transitions.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(events.transitions.count == 2)
        #expect(events.transitions.first?.promotedPlayback?.trackID == "encoded")
        #expect(events.transitions.last?.endedPosition ?? 0 > 0.9)
        #expect(factory.players[1].currentItem == nil)
    }

    private func silentWave() throws -> URL {
        let sampleCount: UInt32 = 8_000
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        append(UInt32(36) + sampleCount * 2)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(sampleCount * 2)
        data.append(Data(count: Int(sampleCount * 2)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        try data.write(to: url)
        return url
    }
}

private nonisolated final class QueueTransitionRecorder: AudioEngineDelegate, Sendable {
    private let storage = Mutex<[AudioEngineTrackEnd]>([])
    var transitions: [AudioEngineTrackEnd] { storage.withLock { $0 } }
    func audioEngineDidChangeState(_ state: AudioEngineState, playbackToken: AudioEnginePlaybackToken) {}
    func audioEngineDidReachEndOfTrack(_ transition: AudioEngineTrackEnd) {
        storage.withLock { $0.append(transition) }
    }
    func audioEngineDidError(_ failure: AudioEngineFailure, playbackToken: AudioEnginePlaybackToken) {}
}
