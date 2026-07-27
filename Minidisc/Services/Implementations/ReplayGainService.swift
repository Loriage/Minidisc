import Foundation

nonisolated enum ReplayGainService {
    static func gainDB(track: DisplayableSong, config: ReplayGainConfig) -> Float {
        computeGain(
            enabled: config.enabled,
            mode: config.mode,
            preAmp: config.preAmp,
            preventClipping: config.preventClipping,
            trackGain: track.replayGainTrackGain,
            trackPeak: track.replayGainTrackPeak,
            albumGain: track.replayGainAlbumGain,
            albumPeak: track.replayGainAlbumPeak,
            baseGain: track.replayGainBaseGain,
            fallbackGain: track.replayGainFallbackGain
        )
    }

    // MARK: - Gain computation

    /// Computes the EQ gain in dB from raw settings values and song RG fields.
    /// Returns 0.0 when disabled or when no gain data is available (play untouched).
    nonisolated static func computeGain(
        enabled: Bool,
        mode: ReplayGainMode,
        preAmp: Double,
        preventClipping: Bool,
        trackGain: Double?,
        trackPeak: Double?,
        albumGain: Double?,
        albumPeak: Double?,
        baseGain: Double?,
        fallbackGain: Double?
    ) -> Float {
        guard enabled else { return 0.0 }

        let selectedGain: Double?
        let selectedPeak: Double?
        switch mode {
        case .track:
            selectedGain = trackGain
            selectedPeak = trackPeak
        case .album:
            selectedGain = albumGain
            selectedPeak = albumPeak
        }

        // Fallback gain has no reliable peak metadata.
        let gainDB: Double
        let peakLinear: Double?
        if let g = selectedGain {
            gainDB = g
            peakLinear = selectedPeak
        } else if let fg = fallbackGain {
            gainDB = fg
            peakLinear = nil
        } else {
            return 0.0
        }

        let totalDB = gainDB + (baseGain ?? 0.0) + preAmp
        let gainLinear = pow(10.0, totalDB / 20.0)

        let finalLinear: Double
        if preventClipping, let peak = peakLinear, peak > 0 {
            finalLinear = min(gainLinear, 1.0 / peak)
        } else {
            finalLinear = gainLinear
        }

        let finalDB = 20.0 * log10(max(finalLinear, 0.0001))
        return Float(finalDB.clamped(to: -96.0...24.0))
    }
}

// MARK: - Comparable clamping helper

fileprivate extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
