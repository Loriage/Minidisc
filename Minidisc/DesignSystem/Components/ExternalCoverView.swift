import SwiftUI

/// Drop-in replacement for `AsyncImage` that routes external cover URLs through
/// `ExternalArtworkCache` (memory → disk → network) instead of hitting the network
/// on every render. Use inside a fixed-size container; the image fills its parent.
struct ExternalCoverView<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.appContainer) private var container
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let requestedURL = url else { return }
            let loadedImage = await container?.externalArtworkCache.image(for: requestedURL)
            guard !Task.isCancelled, requestedURL == url else { return }
            image = loadedImage
        }
    }
}
