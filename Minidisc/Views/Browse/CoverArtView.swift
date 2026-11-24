import SwiftUI

// Reading ArtworkImageCache from a view body observes its whole dictionary and
// refreshes every cover when any entry changes. Resolve one id from a task instead.
/// Resolves cover art through the shared cache, then falls back to AsyncImage.
/// Sizes of at least 480 points use the hero tier unless `tier` overrides it.
struct CoverArtView: View {
    let id: String
    let size: Int?
    var tier: ArtworkTier? = nil
    var cornerRadius: CGFloat = 0
    var placeholderSystemImage: String = "music.note"
    var initialImage: PlatformImage? = nil
    /// Defers loading for mounted rows that are not yet visible.
    var loadingEnabled: Bool = true

    var body: some View {
        CoverArtViewContent(
            id: id,
            size: size,
            tier: tier,
            cornerRadius: cornerRadius,
            placeholderSystemImage: placeholderSystemImage,
            initialImage: initialImage,
            loadingEnabled: loadingEnabled
        )
    }
}

private struct CoverArtViewContent: View {
    let id: String
    let size: Int?
    let tier: ArtworkTier?
    let cornerRadius: CGFloat
    let placeholderSystemImage: String
    let loadingEnabled: Bool

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkCache
    @AppStorage("coverArtUploadVersion") private var coverArtUploadVersion = 0
    @State private var cachedImage: PlatformImage?
    @State private var url: URL?
    @State private var isUnavailable = false
    /// Associates local image state with its source id to prevent stale artwork.
    @State private var displayedId: String?

    init(id: String, size: Int?, tier: ArtworkTier?, cornerRadius: CGFloat, placeholderSystemImage: String, initialImage: PlatformImage?, loadingEnabled: Bool = true) {
        self.id = id
        self.size = size
        self.tier = tier
        self.cornerRadius = cornerRadius
        self.placeholderSystemImage = placeholderSystemImage
        self.loadingEnabled = loadingEnabled
        _cachedImage = State(initialValue: initialImage)
        _displayedId = State(initialValue: initialImage == nil ? nil : id)
    }

    private var resolvedTier: ArtworkTier {
        tier ?? ((size ?? 0) >= 480 ? .hero : .thumb)
    }

    var body: some View {
        ZStack {
            if let cached = cachedImage {
                Image(platformImage: cached)
                    .resizable()
                    .scaledToFill()
            } else if id.hasPrefix("local:") || isUnavailable {
                placeholder
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        GeometryReader { geo in
                            SkeletonBlock(
                                width: geo.size.width,
                                height: geo.size.height,
                                cornerRadius: cornerRadius
                            )
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .task(id: "\(loadingEnabled):\(id):\(resolvedTier.rawValue):\(coverArtUploadVersion):\(container?.serverState.isOnline ?? true)") {
            guard loadingEnabled else { return }
            url = nil
            isUnavailable = false
            let t = resolvedTier
            let online = container?.serverState.isOnline ?? true

            // Task reads do not create the global observation dependency avoided above.
            if let ram = artworkCache.cachedImage(for: id, tier: t) {
                apply(ram, for: id)
                return
            }

            let image = online
                ? await artworkCache.load(coverArtId: id, tier: t)
                : await artworkCache.loadCached(coverArtId: id, tier: t)
            if let image {
                guard !Task.isCancelled else { return }
                apply(image, for: id)
                return
            }

            if id.hasPrefix("local:") {
                cachedImage = nil
                displayedId = nil
                return
            }
            if displayedId == id { return }

            cachedImage = nil
            displayedId = nil
            isUnavailable = !online
            guard online else { return }
            let fallbackURL = await container?.libraryService.coverArtURL(id: id, size: size)
            guard !Task.isCancelled else { return }
            url = fallbackURL
            isUnavailable = fallbackURL == nil
        }
    }

    private func apply(_ image: PlatformImage, for resolvedId: String) {
        cachedImage = image
        displayedId = resolvedId
        url = nil
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [MinidiscColors.accent.opacity(0.25), MinidiscColors.accent.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: placeholderSystemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}
