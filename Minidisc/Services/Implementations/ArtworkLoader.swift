import Foundation
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Loads and caches raw artwork bytes.
///
/// MediaPlayer objects are deliberately created by `NowPlayingCenterPresenter` on
/// `MainActor`; only `Data`, which is `Sendable`, crosses this actor boundary.
actor ArtworkLoader {
    private var cache: [URL: Data] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    /// Returns cached artwork bytes if available, otherwise fetches from `url` injecting
    /// `headers` into the request (required for Cloudflare-protected hosts).
    func data(for url: URL, headers: [String: String]) async -> Data? {
        if let cached = cache[url] { return cached }

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        guard let (data, response) = try? await session.data(for: request),
              !Task.isCancelled,
              !data.isEmpty,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else {
            Logger.artworkCache.warning("ArtworkLoader: failed to fetch artwork from \(url, privacy: .public)")
            return nil
        }

        let normalizedData = await Task.detached(priority: .utility) {
            Self.normalizedArtworkData(data)
        }.value
        guard !Task.isCancelled, let normalizedData else {
            Logger.artworkCache.warning("ArtworkLoader: artwork could not be decoded from \(url, privacy: .public)")
            return nil
        }
        cache[url] = normalizedData
        return normalizedData
    }

    func clearCache() {
        cache.removeAll()
    }

    /// Decodes and bounds the image off MainActor, then returns compact bytes that
    /// MediaPlayer can instantiate without decoding a multi-megapixel source on the UI thread.
    nonisolated private static func normalizedArtworkData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                ] as CFDictionary
              )
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
