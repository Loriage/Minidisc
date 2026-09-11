import SwiftUI

@Observable
@MainActor
final class FullPlayerViewModel {
    private(set) var backgroundColors: [Color] = Array(repeating: .black, count: 4)
    private(set) var coverArtID: String?

    var contentColor: Color { .white }
    var secondaryContentColor: Color { Color.white.opacity(0.7) }

    func updateColors(for coverArtId: String?, colorExtractor: DominantColorExtractor,
                      container: AppContainer?, reduceMotion: Bool = false) async {
        coverArtID = coverArtId
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.25)
        guard let coverArtId else {
            withAnimation(animation) { backgroundColors = Array(repeating: .black, count: 4) }
            return
        }
        if let colors = colorExtractor.cachedBackgroundColors(for: coverArtId) {
            withAnimation(animation) { backgroundColors = colors }
            return
        }
        // Use this cover's existing average until its bands are ready, never the previous song's colors.
        withAnimation(animation) {
            backgroundColors = Array(repeating: colorExtractor.cachedColor(for: coverArtId) ?? .black, count: 4)
        }
        guard let artworkCache = container?.artworkImageCache else { return }
        let image = artworkCache.cachedImage(for: coverArtId, tier: .hero)
            ?? artworkCache.cachedImage(for: coverArtId, tier: .thumb)
        let resolvedImage: PlatformImage?
        if let image { resolvedImage = image }
        else { resolvedImage = await artworkCache.load(coverArtId: coverArtId, tier: .thumb) }
        guard !Task.isCancelled, let resolvedImage,
              let colors = await colorExtractor.backgroundColors(for: coverArtId, image: resolvedImage),
              !Task.isCancelled, coverArtID == coverArtId else { return }
        withAnimation(animation) { backgroundColors = colors }
    }
}
