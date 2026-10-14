import Foundation
import SwiftSonic

nonisolated struct DisplayableSong: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let artist: String?
    let albumId: String?
    let albumName: String?
    let artistId: String?
    let genre: String?
    let duration: TimeInterval
    var discNumber: Int? = nil
    let trackNumber: Int?
    var isDownloaded: Bool
    let coverArtId: String?
    let audioFormat: String?
    let replayGainTrackGain: Double?
    let replayGainTrackPeak: Double?
    let replayGainAlbumGain: Double?
    let replayGainAlbumPeak: Double?
    /// OpenSubsonic: always added to the selected mode's gain when present.
    let replayGainBaseGain: Double?
    /// OpenSubsonic: used as fallback when the selected mode's gain is absent.
    let replayGainFallbackGain: Double?
    var localFile: LocalFileReference? = nil
    /// OpenSubsonic per-track artist credits. `nil` on servers without multi-artist support.
    var artists: [ArtistCredit]? = nil
    /// Source bit rate in kbps as reported by the server, before any transcoding.
    var bitRate: Int? = nil
    var bitDepth: Int? = nil
    /// Source sample rate in Hz.
    var samplingRate: Int? = nil
    var channelCount: Int? = nil

    var isLocalFile: Bool { localFile != nil }
}

/// A credited artist on a track. `id` is nil when the credit only comes from a plain artist string.
nonisolated struct ArtistCredit: Hashable, Sendable, Codable {
    let id: String?
    let name: String
}

extension DisplayableSong {
    nonisolated init(from song: Song, isDownloaded: Bool = false) {
        self.id = song.id
        self.title = song.title
        self.artist = song.artist
        self.albumId = song.albumId
        self.albumName = song.album
        self.artistId = song.artistId
        self.genre = song.genres?.first?.name ?? song.genre
        self.duration = song.duration.map(TimeInterval.init) ?? 0
        self.discNumber = song.discNumber
        self.trackNumber = song.track
        self.isDownloaded = isDownloaded
        self.coverArtId = song.coverArt
        self.audioFormat = song.suffix?.uppercased()
        self.replayGainTrackGain = song.replayGain?.trackGain
        self.replayGainTrackPeak = song.replayGain?.trackPeak
        self.replayGainAlbumGain = song.replayGain?.albumGain
        self.replayGainAlbumPeak = song.replayGain?.albumPeak
        self.replayGainBaseGain = song.replayGain?.baseGain
        self.replayGainFallbackGain = song.replayGain?.fallbackGain
        self.artists = song.artists.flatMap { credits in
            let mapped = credits.map { ArtistCredit(id: $0.id, name: $0.name) }
            return mapped.isEmpty ? nil : mapped
        }
        self.bitRate = song.bitRate
        self.bitDepth = song.bitDepth
        self.samplingRate = song.samplingRate
        self.channelCount = song.channelCount
    }

    @MainActor
    init(from track: DownloadedTrack) {
        self.id = track.songId
        self.title = track.title
        self.artist = track.artist
        self.albumId = track.albumId
        self.albumName = track.album
        self.artistId = track.artistId
        self.genre = track.genre
        self.duration = track.durationSeconds.map(TimeInterval.init) ?? 0
        self.discNumber = track.discNumber
        self.trackNumber = track.trackNumber
        self.isDownloaded = true
        self.coverArtId = track.coverArtId
        self.audioFormat = track.suffix?.uppercased()
        self.replayGainTrackGain = track.replayGainTrackGain
        self.replayGainTrackPeak = track.replayGainTrackPeak
        self.replayGainAlbumGain = track.replayGainAlbumGain
        self.replayGainAlbumPeak = track.replayGainAlbumPeak
        self.replayGainBaseGain = track.replayGainBaseGain
        self.replayGainFallbackGain = track.replayGainFallbackGain
        // Downloads keep no server audio properties; the average bit rate follows from the file itself.
        if let seconds = track.durationSeconds, seconds > 0, track.fileSize > 0 {
            self.bitRate = Int(track.fileSize * 8 / 1000 / Int64(seconds))
        }
    }

    func withDownloaded(_ flag: Bool) -> DisplayableSong {
        var copy = self
        copy.isDownloaded = flag
        return copy
    }
}
