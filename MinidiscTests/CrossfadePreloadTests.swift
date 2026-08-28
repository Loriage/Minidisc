import Foundation
import Testing
@testable import Minidisc

// MARK: - shouldSchedulePrefetch

@Suite("PlayerService.shouldSchedulePrefetch")
struct ShouldSchedulePrefetchTests {

    @Test func gaplessPreloadStillRunsWhenCrossfadeIsOff() {
        // "Off" disables overlap, not the warm standby deck required for a butt-splice.
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 0, remaining: 0) == true)
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 0, remaining: 5) == true)
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 0, remaining: 15) == true)
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 0, remaining: 100) == false)
    }

    @Test func firesWhenRemainingWithinThreshold() {
        // threshold = duration + 15; remaining=20 with duration=8 → 20 <= 23 → true
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 8, remaining: 20) == true)
    }

    @Test func exactlyAtThreshold() {
        // remaining == crossfadeDuration + 15 → should fire (≤)
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 5, remaining: 20) == true)
    }

    @Test func doesNotFireBeyondThreshold() {
        // remaining=21 with duration=5 → 21 > 20 → false
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 5, remaining: 21) == false)
    }

    @Test func firesNearEndOfTrack() {
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 3, remaining: 2) == true)
    }
}

@Suite("PlayerService.shouldProtectTransitionFromCaching")
struct ShouldProtectTransitionFromCachingTests {
    @Test func cancelsCacheBeforeStandbyPreloadWindow() {
        #expect(PlayerService.shouldProtectTransitionFromCaching(crossfadeDuration: 5, remaining: 35))
        #expect(!PlayerService.shouldProtectTransitionFromCaching(crossfadeDuration: 5, remaining: 35.1))
    }

    @Test func protectsGaplessTransitionWhenCrossfadeIsOff() {
        #expect(PlayerService.shouldProtectTransitionFromCaching(crossfadeDuration: 0, remaining: 30))
        #expect(!PlayerService.shouldProtectTransitionFromCaching(crossfadeDuration: 0, remaining: 30.1))
    }
}

@Suite("AVPlayerEngine ReplayGain routing")
struct AVPlayerEngineReplayGainRoutingTests {
    @Test func attenuationUsesDeckVolumeWithoutAudioTap() {
        #expect(!AVPlayerEngine.requiresReplayGainTap(linearGain: 0.5))
        #expect(AVPlayerEngine.replayGainDeckVolumeScale(linearGain: 0.5, tapInstalled: false) == 0.5)
    }

    @Test func boostRequiresAudioTap() {
        #expect(AVPlayerEngine.requiresReplayGainTap(linearGain: 1.5))
        #expect(AVPlayerEngine.replayGainDeckVolumeScale(linearGain: 1.5, tapInstalled: false) == 1)
    }

    @Test func installedTapOwnsTheEntireGain() {
        #expect(AVPlayerEngine.replayGainDeckVolumeScale(linearGain: 0.5, tapInstalled: true) == 1)
    }
}

@Suite("AVPlayerEngine equal-power crossfade")
struct AVPlayerEngineEqualPowerCrossfadeTests {
    @Test func endpointsRouteOneDeckAtATime() {
        let start = AVPlayerEngine.equalPowerLevels(progress: 0)
        let end = AVPlayerEngine.equalPowerLevels(progress: 1)

        #expect(abs(start.outgoing - 1) < 0.0001)
        #expect(abs(start.incoming) < 0.0001)
        #expect(abs(end.outgoing) < 0.0001)
        #expect(abs(end.incoming - 1) < 0.0001)
    }

    @Test func midpointPreservesCombinedPower() {
        let midpoint = AVPlayerEngine.equalPowerLevels(progress: 0.5)
        let combinedPower = midpoint.outgoing * midpoint.outgoing
            + midpoint.incoming * midpoint.incoming

        #expect(abs(combinedPower - 1) < 0.0001)
        #expect(abs(midpoint.outgoing - midpoint.incoming) < 0.0001)
    }

    @Test func progressIsClampedToTheRamp() {
        #expect(AVPlayerEngine.equalPowerLevels(progress: -1).outgoing == 1)
        #expect(abs(AVPlayerEngine.equalPowerLevels(progress: 2).outgoing) < 0.0001)
    }
}

@Suite("PlayerService.effectiveCrossfadeOverlap")
struct EffectiveCrossfadeOverlapTests {
    @Test func usesConfiguredDurationForOrdinaryTransitions() {
        #expect(PlayerService.effectiveCrossfadeOverlap(
            duration: 5,
            disableForGapless: true,
            isGaplessPair: false
        ) == 5)
    }

    @Test func preservesConsecutiveAlbumTracksWhenRequested() {
        #expect(PlayerService.effectiveCrossfadeOverlap(
            duration: 5,
            disableForGapless: true,
            isGaplessPair: true
        ) == 0)
    }

    @Test func canCrossfadeConsecutiveAlbumTracks() {
        #expect(PlayerService.effectiveCrossfadeOverlap(
            duration: 5,
            disableForGapless: false,
            isGaplessPair: true
        ) == 5)
    }
}

// MARK: - isAlbumSequencePair

@Suite("PlayerService.isAlbumSequencePair")
struct IsAlbumSequencePairTests {

    @Test func sameAlbumConsecutiveIsGapless() {
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1,
            currentTrackNumber: 3,
            nextAlbumId: "A", nextDiscNumber: 1, nextTrackNumber: 4
        ) == true)
    }

    @Test func differentAlbumIsNotGapless() {
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1,
            currentTrackNumber: 3,
            nextAlbumId: "B", nextDiscNumber: 1, nextTrackNumber: 4
        ) == false)
    }

    @Test func nonConsecutiveIsNotGapless() {
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1,
            currentTrackNumber: 3,
            nextAlbumId: "A", nextDiscNumber: 1, nextTrackNumber: 5
        ) == false)
    }

    @Test func nextDiscStartsAContinuousAlbumSequence() {
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1, currentTrackNumber: 12,
            nextAlbumId: "A", nextDiscNumber: 2, nextTrackNumber: 1
        ))
    }

    @Test func skippedDiscIsNotContinuous() {
        #expect(!PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1, currentTrackNumber: 12,
            nextAlbumId: "A", nextDiscNumber: 3, nextTrackNumber: 1
        ))
    }

    @Test func nilAlbumIdIsNotGapless() {
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: nil, currentDiscNumber: 1,
            currentTrackNumber: 3,
            nextAlbumId: "A", nextDiscNumber: 1, nextTrackNumber: 4
        ) == false)
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1,
            currentTrackNumber: 3,
            nextAlbumId: nil, nextDiscNumber: 1, nextTrackNumber: 4
        ) == false)
    }

    @Test func nilTrackNumberIsNotGapless() {
        #expect(PlayerService.isAlbumSequencePair(
            currentAlbumId: "A", currentDiscNumber: 1,
            currentTrackNumber: nil,
            nextAlbumId: "A", nextDiscNumber: 1, nextTrackNumber: 4
        ) == false)
    }
}

@Suite("PlayerService.clampedSeekTarget")
struct ClampedSeekTargetTests {
    @Test func clampsMalformedAndOutOfRangeTargets() {
        #expect(PlayerService.clampedSeekTarget(requested: .nan, stateDuration: 180, engineDuration: 180) == nil)
        #expect(PlayerService.clampedSeekTarget(requested: -20, stateDuration: 180, engineDuration: 180) == 0)
        #expect(PlayerService.clampedSeekTarget(requested: 250, stateDuration: 180, engineDuration: 200) == 200)
    }

    @Test func usesUnboundedNonnegativeTargetWhenDurationIsUnknown() {
        #expect(PlayerService.clampedSeekTarget(requested: 42, stateDuration: 0, engineDuration: 0) == 42)
    }
}
