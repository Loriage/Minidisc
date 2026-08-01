import Testing
import Darwin
import SwiftSonic
@testable import Minidisc

// Convenience wrapper so individual tests don't repeat all parameters.
private func gain(
    enabled: Bool = true,
    mode: ReplayGainMode = .track,
    preAmp: Double = 0,
    preventClipping: Bool = true,
    trackGain: Double? = nil,
    trackPeak: Double? = nil,
    albumGain: Double? = nil,
    albumPeak: Double? = nil,
    baseGain: Double? = nil,
    fallbackGain: Double? = nil
) -> Float {
    ReplayGainService.computeGain(
        enabled: enabled,
        mode: mode,
        preAmp: preAmp,
        preventClipping: preventClipping,
        trackGain: trackGain,
        trackPeak: trackPeak,
        albumGain: albumGain,
        albumPeak: albumPeak,
        baseGain: baseGain,
        fallbackGain: fallbackGain
    )
}

private let epsilon: Float = 0.01

@Suite("ReplayGainService.computeGain")
struct ReplayGainServiceComputeGainTests {

    @Test("disabled always returns 0 dB regardless of gain data")
    func disabledReturnsZero() {
        let result = gain(enabled: false, trackGain: -6)
        #expect(result == 0.0)
    }

    @Test("no gain data returns 0 dB and pre-amp is NOT applied")
    func noGainDataReturnsZeroNoPreAmp() {
        let result = gain(preAmp: 6)
        #expect(result == 0.0)
    }

    @Test("track mode uses trackGain")
    func trackModeUsesTrackGain() {
        let result = gain(mode: .track, trackGain: -6, albumGain: -3)
        let expected = Float(-6.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("album mode uses albumGain")
    func albumModeUsesAlbumGain() {
        let result = gain(mode: .album, trackGain: -6, albumGain: -3)
        let expected = Float(-3.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("Adèle Castillon tags apply their exact negative gain")
    func adeleCastillonTags() {
        let track = gain(
            mode: .track,
            trackGain: -9.57,
            trackPeak: 0.994904,
            albumGain: -9.57,
            albumPeak: 0.994904
        )
        let album = gain(
            mode: .album,
            trackGain: -9.57,
            trackPeak: 0.994904,
            albumGain: -9.57,
            albumPeak: 0.994904
        )

        #expect(abs(track - (-9.57)) < epsilon)
        #expect(abs(album - (-9.57)) < epsilon)
    }

    @Test("Hozier tags preserve track and album normalization modes")
    func hozierTags() {
        let track = gain(
            mode: .track,
            trackGain: -10.38,
            trackPeak: 0.999969,
            albumGain: -9.67,
            albumPeak: 0.999969
        )
        let album = gain(
            mode: .album,
            trackGain: -10.38,
            trackPeak: 0.999969,
            albumGain: -9.67,
            albumPeak: 0.999969
        )

        #expect(abs(track - (-10.38)) < epsilon)
        #expect(abs(album - (-9.67)) < epsilon)
    }

    @Test("preAmp is added to selected gain")
    func preAmpAddedToGain() {
        let result = gain(preAmp: 3, trackGain: -6)
        let expected = Float(-3.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("baseGain is always added to selected gain when present")
    func baseGainAdded() {
        let result = gain(trackGain: -6, baseGain: 2)
        let expected = Float(-4.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("track mode uses album gain before fallbackGain when track gain is missing")
    func trackModeUsesAlbumBeforeFallback() {
        let result = gain(mode: .track, albumGain: -6, fallbackGain: -4)
        let expected = Float(-6.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("album mode uses track gain before fallbackGain when album gain is missing")
    func albumModeUsesTrackBeforeFallback() {
        let result = gain(mode: .album, trackGain: -6, fallbackGain: -4)
        let expected = Float(-6.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("fallbackGain is used when both standard gains are missing")
    func fallbackGainUsedWhenBothModesAreMissing() {
        let result = gain(mode: .track, fallbackGain: -4)
        let expected = Float(-4.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("preAmp is applied when only fallbackGain is available")
    func preAmpAppliedWithFallbackGain() {
        let result = gain(preAmp: 2, fallbackGain: -4)
        let expected = Float(-2.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("alternate gain keeps its matching peak for clipping prevention")
    func alternateGainUsesMatchingPeak() {
        let result = gain(
            mode: .track,
            preventClipping: true,
            trackGain: nil,
            albumGain: 10,
            albumPeak: 0.5,
            fallbackGain: -4
        )
        let expected = Float(-20.0 * log10(0.5))
        #expect(abs(result - expected) < epsilon)
    }

    @Test("preventClipping clamps gain via peak")
    func preventClippingClampsGain() {
        // +6 dB gain, peak = 0.7 → max safe is 1/0.7 ≈ 1.4286 linear → ~3.1 dB
        // Without clipping it would be +6 dB; with clipping it should be ≤ 3.1 dB
        let withClip = gain(preventClipping: true, trackGain: 6, trackPeak: 0.7)
        let withoutClip = gain(preventClipping: false, trackGain: 6, trackPeak: 0.7)
        #expect(withClip < withoutClip)
        // Max safe = 20*log10(1/0.7) ≈ 3.1 dB
        let maxSafe = 20.0 * log10(1.0 / 0.7)
        #expect(abs(Double(withClip) - maxSafe) < 0.02)
    }

    @Test("preventClipping off allows the full boost")
    func preventClippingOffAllowsBoost() {
        let result = gain(preventClipping: false, trackGain: 6, trackPeak: 0.7)
        #expect(abs(result - 6.0) < epsilon)
    }

    @Test("missing peak assumes full scale when clipping prevention is enabled")
    func missingPeakAssumesFullScale() {
        let result = gain(preventClipping: true, trackGain: 6, trackPeak: nil)
        #expect(abs(result) < epsilon)
    }

    @Test("malformed peak assumes full scale when clipping prevention is enabled", arguments: [
        0.0,
        -0.5,
        Double.nan,
        Double.infinity,
    ])
    func malformedPeakAssumesFullScale(peak: Double) {
        let result = gain(preventClipping: true, trackGain: 6, trackPeak: peak)
        #expect(abs(result) < epsilon)
    }

    @Test("missing peak does not alter an attenuation")
    func missingPeakKeepsNegativeGain() {
        let result = gain(preventClipping: true, trackGain: -9.57, trackPeak: nil)
        #expect(abs(result - (-9.57)) < epsilon)
    }

    @Test("peak above full scale attenuates even at zero ReplayGain")
    func overFullScalePeakIsAttenuated() {
        let result = gain(preventClipping: true, trackGain: 0, trackPeak: 1.2)
        let expected = Float(-20.0 * log10(1.2))
        #expect(abs(result - expected) < epsilon)
    }

    @Test("very negative gain reaches the documented -96 dB lower bound")
    func extremelyNegativeGainUsesLowerBound() {
        let result = gain(trackGain: -200)
        #expect(abs(result - (-96.0)) < epsilon)
    }

    @Test("output is clamped to +24 dB upper bound")
    func clampedToUpperBound() {
        let result = gain(preventClipping: false, trackGain: 100)
        #expect(result == 24.0)
    }

    @Test("album mode falls back to fallbackGain when albumGain is nil")
    func albumModeFallsBackToFallback() {
        let result = gain(mode: .album, albumGain: nil, fallbackGain: -5)
        let expected = Float(-5.0)
        #expect(abs(result - expected) < epsilon)
    }

    @Test("non-finite preferred gain falls back to the other standard gain")
    func nonFinitePreferredGainFallsBack() {
        let result = gain(mode: .track, trackGain: .nan, albumGain: -5, fallbackGain: -3)
        #expect(abs(result - (-5.0)) < epsilon)
    }

    @Test("OpenSubsonic ReplayGain values map without unit conversion")
    func openSubsonicMapping() {
        let apiSong = Song(
            id: "hozier-01",
            title: "Take Me to Church",
            replayGain: ReplayGain(
                trackGain: -10.38,
                albumGain: -9.67,
                trackPeak: 0.999969,
                albumPeak: 0.999969
            )
        )
        let song = DisplayableSong(from: apiSong)

        #expect(song.replayGainTrackGain == -10.38)
        #expect(song.replayGainAlbumGain == -9.67)
        #expect(song.replayGainTrackPeak == 0.999969)
        #expect(song.replayGainAlbumPeak == 0.999969)
    }

    @Test("zero preAmp with track gain returns track gain unchanged")
    func zeroPreAmpIsTransparent() {
        let result = gain(preAmp: 0, trackGain: -8.5)
        #expect(abs(result - (-8.5)) < epsilon)
    }
}
