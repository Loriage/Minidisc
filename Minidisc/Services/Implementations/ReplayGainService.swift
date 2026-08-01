import Foundation

nonisolated enum ReplayGainService {
    private struct GainCandidate {
        let gainDB: Double
        let peakLinear: Double?
    }

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

        let preferredGain: Double?
        let preferredPeak: Double?
        let alternateGain: Double?
        let alternatePeak: Double?
        switch mode {
        case .track:
            preferredGain = trackGain
            preferredPeak = trackPeak
            alternateGain = albumGain
            alternatePeak = albumPeak
        case .album:
            preferredGain = albumGain
            preferredPeak = albumPeak
            alternateGain = trackGain
            alternatePeak = trackPeak
        }

        // ReplayGain requires using the other standard gain when the requested mode is absent.
        // OpenSubsonic's fallbackGain is only the final fallback when neither tag is usable.
        guard let candidate = candidate(
            preferredGain: preferredGain,
            preferredPeak: preferredPeak,
            alternateGain: alternateGain,
            alternatePeak: alternatePeak,
            fallbackGain: fallbackGain
        ) else { return 0.0 }

        let validBaseGain = finite(baseGain) ?? 0.0
        let validPreAmp = preAmp.isFinite ? preAmp : 0.0
        let totalDB = candidate.gainDB + validBaseGain + validPreAmp

        let finalDB: Double
        if preventClipping {
            // The specification requires assuming full scale when peak metadata is absent or
            // malformed. This keeps a positive gain or pre-amp from clipping an unknown source.
            let peak = validPeak(candidate.peakLinear) ?? 1.0
            let maximumSafeDB = -20.0 * log10(peak)
            finalDB = min(totalDB, maximumSafeDB)
        } else {
            finalDB = totalDB
        }

        return Float(finalDB.clamped(to: -96.0...24.0))
    }

    private nonisolated static func candidate(
        preferredGain: Double?,
        preferredPeak: Double?,
        alternateGain: Double?,
        alternatePeak: Double?,
        fallbackGain: Double?
    ) -> GainCandidate? {
        if let gain = finite(preferredGain) {
            return GainCandidate(gainDB: gain, peakLinear: preferredPeak)
        }
        if let gain = finite(alternateGain) {
            return GainCandidate(gainDB: gain, peakLinear: alternatePeak)
        }
        if let gain = finite(fallbackGain) {
            return GainCandidate(gainDB: gain, peakLinear: nil)
        }
        return nil
    }

    private nonisolated static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private nonisolated static func validPeak(_ value: Double?) -> Double? {
        guard let value = finite(value), value > 0 else { return nil }
        return value
    }
}

// MARK: - Comparable clamping helper

fileprivate extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
