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

// MARK: - shouldProceedWithPrefetch

@Suite("PlayerService.shouldProceedWithPrefetch")
struct ShouldProceedWithPrefetchTests {

    @Test func proceedsOnWifi() {
        #expect(PlayerService.shouldProceedWithPrefetch(isExpensive: false, allowCellular: false) == true)
    }

    @Test func proceedsOnCellularWhenAllowed() {
        #expect(PlayerService.shouldProceedWithPrefetch(isExpensive: true, allowCellular: true) == true)
    }

    @Test func blockedOnCellularWhenNotAllowed() {
        #expect(PlayerService.shouldProceedWithPrefetch(isExpensive: true, allowCellular: false) == false)
    }

    @Test func proceedsWhenNotExpensiveRegardlessOfAllowCellular() {
        // isExpensive=false means we're on Wi-Fi; allowCellular flag is irrelevant
        #expect(PlayerService.shouldProceedWithPrefetch(isExpensive: false, allowCellular: true) == true)
        #expect(PlayerService.shouldProceedWithPrefetch(isExpensive: false, allowCellular: false) == true)
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

// MARK: - isGaplessPair

@Suite("PlayerService.isGaplessPair")
struct IsGaplessPairTests {

    @Test func sameAlbumConsecutiveIsGapless() {
        #expect(PlayerService.isGaplessPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: 4
        ) == true)
    }

    @Test func differentAlbumIsNotGapless() {
        #expect(PlayerService.isGaplessPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "B", nextTrackNumber: 4
        ) == false)
    }

    @Test func nonConsecutiveIsNotGapless() {
        #expect(PlayerService.isGaplessPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: 5
        ) == false)
    }

    @Test func nilAlbumIdIsNotGapless() {
        #expect(PlayerService.isGaplessPair(
            currentAlbumId: nil, currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: 4
        ) == false)
        #expect(PlayerService.isGaplessPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: nil, nextTrackNumber: 4
        ) == false)
    }

    @Test func nilTrackNumberIsNotGapless() {
        #expect(PlayerService.isGaplessPair(
            currentAlbumId: "A", currentTrackNumber: nil,
            nextAlbumId: "A", nextTrackNumber: 4
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
