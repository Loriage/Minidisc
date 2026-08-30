import SwiftUI

@Observable
@MainActor
final class FullPlayerViewModel {
    var dominantColor: Color = .black

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    var contentColor: Color { .white }
    var secondaryContentColor: Color { Color.white.opacity(0.7) }

    func updateColors(for coverArtId: String?, colorExtractor: DominantColorExtractor, container: AppContainer?) async {
        guard let coverArtId else {
            withAnimation(.easeOut(duration: 0.25)) {
                dominantColor = .black
            }
            return
        }
        // Theme the page INSTANTLY from the already-memoized dominant colour (it's cached app-wide by the cards /
        // mini player), so the background is coloured the moment the player opens — no black flash while the
        // cover downloads.
        let cachedColor = colorExtractor.cachedColor(for: coverArtId)
        if let cachedColor {
            withAnimation(.easeOut(duration: 0.25)) {
                dominantColor = cachedColor
            }
            return
        }
        // Resolve the cover only when its color is not cached; the artwork view loads independently.
        let url: URL?
        if let localURL = await container?.downloadService.localCoverArtURL(forId: coverArtId) {
            url = localURL
        } else {
            url = await container?.libraryService.coverArtURL(id: coverArtId, size: 300)
        }
        guard let url, let (data, _) = try? await session.data(from: url) else { return }
        // Decode (+ average if not cached) OFF the main actor so a track change does not hitch the UI.
        let packed: Int? = await Task.detached(priority: .userInitiated) { () -> Int? in
            guard let image = PlatformImage(data: data) else { return nil }
            return DominantColorExtractor.packedAverageColor(from: image)
        }.value
        guard !Task.isCancelled, let packed else { return }
        let color = colorExtractor.storeColor(packed: packed, for: coverArtId)
        withAnimation(.easeOut(duration: 0.25)) {
            dominantColor = color
        }
    }
}
