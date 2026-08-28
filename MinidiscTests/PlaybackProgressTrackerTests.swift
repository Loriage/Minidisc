import Foundation
import Testing
@testable import Minidisc

@Suite("Playback progress tracker")
struct PlaybackProgressTrackerTests {
    private func makeSong(duration: TimeInterval = 120) -> DisplayableSong {
        DisplayableSong(
            id: "track",
            title: "Track",
            artist: "Artist",
            albumId: "album",
            albumName: "Album",
            artistId: "artist",
            genre: "Rock",
            duration: duration,
            trackNumber: 1,
            isDownloaded: false,
            coverArtId: nil,
            audioFormat: "FLAC",
            replayGainTrackGain: nil,
            replayGainTrackPeak: nil,
            replayGainAlbumGain: nil,
            replayGainAlbumPeak: nil,
            replayGainBaseGain: nil,
            replayGainFallbackGain: nil
        )
    }

    private func makeTracker(
        accumulatedTime: Int,
        startedAt: Date = Date(timeIntervalSince1970: 500)
    ) -> PlaybackProgressTracker {
        var tracker = PlaybackProgressTracker()
        tracker.startTrack(at: startedAt)
        tracker.record(progress: 0, isPlaying: true)
        if accumulatedTime > 0 {
            for second in 1...accumulatedTime {
                tracker.record(progress: TimeInterval(second), isPlaying: true)
            }
        }
        return tracker
    }

    @Test("counts only continuous forward progress")
    func countsContinuousProgress() {
        var tracker = PlaybackProgressTracker()
        tracker.startTrack()

        tracker.record(progress: 10, isPlaying: true)
        tracker.record(progress: 10.5, isPlaying: true)
        tracker.record(progress: 11, isPlaying: true)
        tracker.record(progress: 20, isPlaying: true)
        tracker.record(progress: 19, isPlaying: true)

        #expect(tracker.accumulatedTime == 1)
    }

    @Test("pause and seek baselines do not count unheard time")
    func breaksContinuity() {
        var tracker = PlaybackProgressTracker()
        tracker.startTrack()
        tracker.record(progress: 1, isPlaying: true)
        tracker.record(progress: 1.5, isPlaying: true)
        tracker.record(progress: 2, isPlaying: false)
        tracker.record(progress: 30, isPlaying: true)
        tracker.record(progress: 30.5, isPlaying: true)
        tracker.setBaseline(90)
        tracker.record(progress: 90.5, isPlaying: true)

        #expect(tracker.accumulatedTime == 1.5)
    }

    @Test("resume establishes a start date and progress baseline")
    func resumeInitializesRestoredTrack() {
        var tracker = PlaybackProgressTracker()
        let startedAt = Date(timeIntervalSince1970: 1_000)

        tracker.resume(at: 42, startedAt: startedAt)
        tracker.record(progress: 42.5, isPlaying: true)

        #expect(tracker.trackStartDate == startedAt)
        #expect(tracker.accumulatedTime == 0.5)
    }

    @Test("crossfade promotion preserves already audible playback")
    func promotedPlaybackIncludesOverlap() {
        var tracker = PlaybackProgressTracker()
        let startedAt = Date(timeIntervalSince1970: 1_500)

        tracker.startTrack(at: startedAt, baseline: 5, accumulatedTime: 5)
        tracker.record(progress: 5.5, isPlaying: true)

        #expect(tracker.trackStartDate == startedAt)
        #expect(tracker.accumulatedTime == 5.5)
    }

    @Test("playback events require thirty listened seconds")
    func buildsPlaybackEventAtThreshold() throws {
        var tracker = PlaybackProgressTracker()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let serverId = UUID()
        tracker.startTrack(at: startedAt)
        tracker.record(progress: 0, isPlaying: true)
        for second in 1...30 {
            tracker.record(progress: TimeInterval(second), isPlaying: true)
        }

        let event = try #require(
            tracker.playbackEvent(
                song: makeSong(),
                trackDuration: 120,
                wasCompleted: true,
                serverId: serverId
            )
        )

        #expect(event.durationListened == 30)
        #expect(event.timestamp == startedAt)
        #expect(event.wasCompleted)
        #expect(event.serverId == serverId.uuidString)
    }

    @Test("playback events reject shorter listening time")
    func rejectsPlaybackEventBelowThreshold() {
        var tracker = PlaybackProgressTracker()
        tracker.startTrack()
        tracker.record(progress: 0, isPlaying: true)
        for second in 1...29 {
            tracker.record(progress: TimeInterval(second), isPlaying: true)
        }

        let event = tracker.playbackEvent(
            song: makeSong(),
            trackDuration: 120,
            wasCompleted: false,
            serverId: UUID()
        )

        #expect(event == nil)
    }

    @Test("scrobble threshold remains one-shot until the next track")
    func scrobbleThresholdResetsPerTrack() {
        var tracker = PlaybackProgressTracker()
        let startedAt = Date(timeIntervalSince1970: 3_000)
        tracker.startTrack(at: startedAt)
        tracker.record(progress: 0, isPlaying: true)
        for second in 1...60 {
            tracker.record(progress: TimeInterval(second), isPlaying: true)
        }

        #expect(
            tracker.scrobbleStartDateIfThresholdMet(trackDuration: 120) == startedAt
        )
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 120) == nil)

        tracker.startTrack(at: startedAt.addingTimeInterval(120))
        tracker.record(progress: 0, isPlaying: true)
        for second in 1...60 {
            tracker.record(progress: TimeInterval(second), isPlaying: true)
        }
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 120) != nil)
    }

    @Test("scrobble fires at half of an ordinary track")
    func scrobbleFiresAtHalfDuration() {
        var tracker = makeTracker(accumulatedTime: 50)
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 100) != nil)
    }

    @Test("scrobble threshold is capped at four minutes")
    func scrobbleThresholdIsCapped() {
        var tracker = makeTracker(accumulatedTime: 240)
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 600) != nil)
    }

    @Test("scrobble rejects insufficient listening time")
    func scrobbleRejectsInsufficientTime() {
        var tracker = makeTracker(accumulatedTime: 49)
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 100) == nil)
    }

    @Test("scrobble rejects tracks shorter than thirty seconds")
    func scrobbleRejectsShortTracks() {
        var tracker = makeTracker(accumulatedTime: 20)
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 20) == nil)
    }

    @Test("scrobble still requires half the track at thirty seconds")
    func scrobbleRejectsMinimumDurationBelowHalf() {
        var tracker = makeTracker(accumulatedTime: 10)
        #expect(tracker.scrobbleStartDateIfThresholdMet(trackDuration: 30) == nil)
    }
}
