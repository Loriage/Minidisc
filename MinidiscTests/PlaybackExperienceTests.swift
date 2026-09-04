import Foundation
import Testing
@testable import Minidisc

@Suite @MainActor
struct PlaybackPresentationTests {
    @Test func briefTrackLoadingDoesNotFlashAStatusAndPauseCancelsDelayedStatus() async throws {
        let state = PlayerState(waitingMessageDelay: .milliseconds(40))
        state.playbackState = .loading
        #expect(state.playbackStatusMessage == nil)
        state.playbackState = .playing
        state.waitingReason = nil
        try await Task.sleep(for: .milliseconds(80))
        #expect(state.playbackStatusMessage == nil)

        state.playbackState = .loading
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.playbackStatusMessage == PlaybackWaitingReason.loading.title)
        state.playbackState = .paused
        #expect(state.playbackStatusMessage == nil)
        state.playbackState = .loading
        state.playbackState = .paused
        try await Task.sleep(for: .milliseconds(80))
        #expect(state.playbackStatusMessage == nil)
    }
    @Test func loadingCanBePausedAndLateBufferingDoesNotOverridePause() {
        let state = PlayerState()
        state.playbackState = .loading
        #expect(state.wantsPlayback)
        #expect(state.waitingReason == .loading)
        state.playbackState = .playing
        state.waitingReason = .reconnecting
        #expect(state.wantsPlayback)
        state.playbackState = .paused
        #expect(!state.wantsPlayback)
        #expect(state.playbackStatusMessage == nil)
        state.waitingReason = .reconnecting
        #expect(state.playbackStatusMessage == nil)
    }

    @Test func terminalFailureHasAVisibleExplanation() {
        let state = PlayerState()
        state.playbackState = .error(.mediaNotFound(songId: "test"))
        #expect(!state.wantsPlayback)
        #expect(state.playbackStatusMessage?.isEmpty == false)
    }
}

@Suite struct PlaybackExperienceTests {
    @Test func startupRequiresProgressAndIgnoresASeek() {
        var metrics = PlaybackExperienceMetrics()
        metrics.observe(.command(.play(queueCount: 1, startIndex: 0)), elapsed: 1)
        metrics.observe(.engineStateChanged(.playing), elapsed: 2)
        metrics.observeProgress(0, elapsed: 2)
        metrics.observeProgress(0, elapsed: 2.5)
        #expect(metrics.startupDurations.isEmpty)
        metrics.observeProgress(80, elapsed: 3)
        #expect(metrics.startupDurations.isEmpty)
        metrics.observeProgress(80.5, elapsed: 3.5)
        #expect(metrics.startupDurations == [2.5])
    }

    @Test func pauseIsNotAnInterruptionAndBufferCallbacksCountOnce() {
        var metrics = PlaybackExperienceMetrics()
        metrics.observe(.command(.resume), elapsed: 0)
        metrics.observeProgress(0, elapsed: 1)
        metrics.observeProgress(0.5, elapsed: 1.5)
        metrics.observe(.engineStateChanged(.buffering), elapsed: 2)
        metrics.observe(.engineStateChanged(.paused), elapsed: 2.1)
        metrics.observe(.engineStateChanged(.buffering), elapsed: 2.2)
        #expect(metrics.interruptions == 1)
        metrics.observe(.command(.pause), elapsed: 3)
        metrics.observe(.engineStateChanged(.paused), elapsed: 3.1)
        #expect(metrics.interruptions == 1)
    }

    @Test func failedStartupIsCountedOnce() {
        var metrics = PlaybackExperienceMetrics()
        metrics.observe(.command(.resume), elapsed: 0)
        metrics.observe(.playbackStateChanged(.error), elapsed: 1)
        metrics.observe(.playbackStateChanged(.error), elapsed: 1.1)
        #expect(metrics.failedStarts == 1)
        #expect(metrics.percentile(0.95) == nil)
    }
}
