// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
@testable import Minidisc

// MARK: - shouldSchedulePrefetch

@Suite("PlayerService.shouldSchedulePrefetch")
struct ShouldSchedulePrefetchTests {

    @Test func dormantWhenDurationIsZero() {
        // Default crossfade duration = 0 → prefetch must never fire
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 0, remaining: 0) == false)
        #expect(PlayerService.shouldSchedulePrefetch(crossfadeDuration: 0, remaining: 5) == false)
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
