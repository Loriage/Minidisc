import SwiftUI

@MainActor
enum PlaylistGradientResolver {
    static func resolve(
        form: PlaylistGradientShape,
        firstTrackCoverArtId: String?,
        artworkImageCache: ArtworkImageCache,
        colorExtractor: DominantColorExtractor
    ) async -> PlaylistGradientSpec {
        if form.meshPalette != nil { return .neutral(shape: form) }
        guard let coverArtId = firstTrackCoverArtId else {
            return .neutral(shape: form)
        }
        if let cached = colorExtractor.cachedColor(for: coverArtId) {
            return PlaylistGradientSpec(shape: form, baseColor: cached.vibranceBoosted())
        }
        guard let image = await artworkImageCache.load(coverArtId: coverArtId, tier: .thumb) else {
            return .neutral(shape: form)
        }
        let packed = await Task.detached(priority: .userInitiated) {
            DominantColorExtractor.packedAverageColor(from: image)
        }.value
        guard let packed else { return .neutral(shape: form) }
        let color = colorExtractor.storeColor(packed: packed, for: coverArtId)
        return color == .clear ? .neutral(shape: form) : PlaylistGradientSpec(shape: form, baseColor: color.vibranceBoosted())
    }
}
