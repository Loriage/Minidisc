import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Minidisc

private nonisolated final class ResetTestPlayer: AVPlayer, @unchecked Sendable {
    private let forcedFailure = Mutex(false)

    func failPermanently() { forcedFailure.withLock { $0 = true } }

    override var status: AVPlayer.Status {
        forcedFailure.withLock { $0 } ? .failed : super.status
    }
}

private nonisolated final class ResetTestPlayerFactory: Sendable {
    private let storage = Mutex<[ResetTestPlayer]>([])

    var players: [ResetTestPlayer] { storage.withLock { $0 } }

    func makePlayer() -> AVPlayer {
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
            crossfadeDuration: 0, leadInTrim: 0, replayGainDB: -3
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

    @Test(arguments: [0, 1])
    func nextDiscardsATerminalPlayerBeforeItsFailureCallbackArrives(failedDeck: Int) throws {
        let factory = ResetTestPlayerFactory()
        let engine = AVPlayerEngine(playerFactory: factory.makePlayer)
        let url = try silentWave()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        let oldToken = engine.play(trackID: "first", url: url, headers: [:])
        factory.players[failedDeck].failPermanently()

        let nextToken = engine.play(trackID: "second", url: url, headers: [:])
        #expect(factory.players.count == 4)
        #expect(factory.players.prefix(2).allSatisfy { $0.currentItem == nil })
        #expect(factory.players[2].currentItem != nil)
        #expect(nextToken.rawValue > oldToken.rawValue)
        #expect(!engine.isReady)
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
