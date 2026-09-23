import SwiftUI
import CoreImage
import OSLog

import UIKit

/// Caches average artwork colors. UserDefaults permits synchronous cold-start hydration.
@MainActor
@Observable
final class DominantColorExtractor {
    // v3 invalidates the bottom-strip averages stored by v2.
    private static let userDefaultsKey = "minidisc.dominantColor.cache.v3"
    private static let legacyUserDefaultsKey = "minidisc.dominantColor.cache.v2"
    private static let overridesKey = "minidisc.dominantColor.overrides"

    // Memoization must not invalidate views that read colors during body evaluation.
    @ObservationIgnored private var cache: [String: Color] = [:]
    /// Separate cache for lower-20% averages used by immersive headers.
    @ObservationIgnored private var bottomStripCache: [String: Color] = [:]
    @ObservationIgnored private var backgroundPaletteCache: [String: [Color]] = [:]
    @ObservationIgnored private var paletteRevision: UInt64 = 0
    private let bandSampler = ArtworkBandSampler()
    /// Observed overrides take precedence over extracted colors.
    private var colorOverrides: [String: Color] = [:]
    private let ciContext = CIContext(options: [.workingColorSpace: kCFNull as Any])

    init() {
        UserDefaults.standard.removeObject(forKey: Self.legacyUserDefaultsKey)
        let stored = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        var hydrated: [String: Color] = [:]
        hydrated.reserveCapacity(stored.count)
        for (key, value) in stored {
            if let packed = value as? Int {
                hydrated[key] = Self.unpack(packed)
            }
        }
        cache = hydrated

        let storedOverrides = UserDefaults.standard.dictionary(forKey: Self.overridesKey) ?? [:]
        var hydratedOverrides: [String: Color] = [:]
        for (key, value) in storedOverrides {
            if let packed = value as? Int { hydratedOverrides[key] = Self.unpack(packed) }
        }
        colorOverrides = hydratedOverrides
        Logger.dominantColor.debug("Hydrated \(hydrated.count) dominant colors + \(hydratedOverrides.count) overrides.")
    }

    /// Returns the dominant color for the given image, or Color.clear if unavailable.
    /// Checks the in-memory cache (hydrated from UserDefaults at launch) before processing.
    func dominantColor(for coverArtId: String?, image: PlatformImage?) -> Color {
        guard let coverArtId else { return .clear }
        if let override = colorOverrides[coverArtId] { return override }
        if let cached = cache[coverArtId] { return cached }
        guard let image else { return .clear }
        guard let result = extract(from: image) else { return .clear }
        cache[coverArtId] = result.color
        persistColor(result.packed, forKey: coverArtId)
        return result.color
    }

    /// Returns the lower-20% average, honoring overrides. A nil image performs a cache-only read.
    func bottomStripColor(for coverArtId: String?, image: PlatformImage?) -> Color {
        guard let coverArtId else { return .clear }
        if let override = colorOverrides[coverArtId] { return override }
        if let cached = bottomStripCache[coverArtId] { return cached }
        guard let image else { return .clear }
        guard let result = extract(from: image, bottomStrip: true) else { return .clear }
        bottomStripCache[coverArtId] = result.color
        return result.color
    }

    func cachedColor(for coverArtId: String) -> Color? {
        colorOverrides[coverArtId] ?? cache[coverArtId]
    }

    func cachedBackgroundColors(for coverArtId: String) -> [Color]? {
        if let override = colorOverrides[coverArtId] { return Array(repeating: override, count: 4) }
        return backgroundPaletteCache[coverArtId]
    }

    func backgroundColors(for coverArtId: String, image: PlatformImage) async -> [Color]? {
        if let cached = cachedBackgroundColors(for: coverArtId) { return cached }
        let revision = paletteRevision
        guard let packed = await bandSampler.sample(image), !Task.isCancelled,
              revision == paletteRevision else { return nil }
        let colors = packed.map(Self.unpack)
        backgroundPaletteCache[coverArtId] = colors
        // A manual choice made during extraction still takes precedence.
        return cachedBackgroundColors(for: coverArtId)
    }

    func colorOverride(for coverArtId: String) -> Color? { colorOverrides[coverArtId] }

    /// Stores the choice under both album and track cover IDs, which can differ for the same artwork.
    func setColorOverride(_ color: Color?, forIds ids: [String]) {
        let packed = color.flatMap(Self.pack)
        var dict = UserDefaults.standard.dictionary(forKey: Self.overridesKey) ?? [:]
        for id in ids where !id.isEmpty {
            if let color {
                colorOverrides[id] = color
                if let packed { dict[id] = packed }
            } else {
                colorOverrides.removeValue(forKey: id)
                dict.removeValue(forKey: id)
            }
        }
        UserDefaults.standard.set(dict, forKey: Self.overridesKey)
    }

    private static func pack(_ color: Color) -> Int? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Int(max(0, min(1, r)) * 255) << 16) | (Int(max(0, min(1, g)) * 255) << 8) | Int(max(0, min(1, b)) * 255)
    }

    /// Stores a packed color produced off-main by `packedAverageColor(from:)` and returns the Color,
    /// so callers that already extracted off the main actor don't repeat the CoreImage work here.
    func storeColor(packed: Int?, for coverArtId: String) -> Color {
        if let cached = cache[coverArtId] { return cached }
        guard let packed else { return .clear }
        let color = Self.unpack(packed)
        cache[coverArtId] = color
        persistColor(packed, forKey: coverArtId)
        return color
    }

    nonisolated static func packedAverageColor(from image: PlatformImage) -> Int? {
        guard let cgImage = image.cgImage else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        let inputExtent = CIVector(
            x: extent.origin.x,
            y: extent.origin.y,
            z: extent.size.width,
            w: extent.size.height
        )
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: inputExtent
        ]),
        let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return (Int(bitmap[0]) << 16) | (Int(bitmap[1]) << 8) | Int(bitmap[2])
    }

    func invalidate(for coverArtId: String?) {
        guard let coverArtId else { return }
        paletteRevision &+= 1
        backgroundPaletteCache.removeValue(forKey: coverArtId)
        cache.removeValue(forKey: coverArtId)
        bottomStripCache.removeValue(forKey: coverArtId)
        removePersistedColor(forKey: coverArtId)
    }

    func clearCache() {
        paletteRevision &+= 1
        backgroundPaletteCache.removeAll()
        cache.removeAll()
        bottomStripCache.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
    }

    static func unpack(_ packed: Int) -> Color {
        Color(
            red: Double((packed >> 16) & 0xFF) / 255.0,
            green: Double((packed >> 8) & 0xFF) / 255.0,
            blue: Double(packed & 0xFF) / 255.0
        )
    }

    private func persistColor(_ packed: Int, forKey key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        dict[key] = packed
        UserDefaults.standard.set(dict, forKey: Self.userDefaultsKey)
    }

    private func removePersistedColor(forKey key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        dict.removeValue(forKey: key)
        UserDefaults.standard.set(dict, forKey: Self.userDefaultsKey)
    }

    private func extract(from image: PlatformImage, bottomStrip: Bool = false) -> (color: Color, packed: Int)? {
        guard let cgImage = image.cgImage else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        // Core Image’s bottom-left origin puts the lower 20% at extent.minY.
        let stripHeight = bottomStrip ? max(1, extent.size.height * 0.20) : extent.size.height
        let inputExtent = CIVector(
            x: extent.origin.x,
            y: extent.origin.y,
            z: extent.size.width,
            w: stripHeight
        )

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: inputExtent
        ]),
        let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let packed = (Int(bitmap[0]) << 16) | (Int(bitmap[1]) << 8) | Int(bitmap[2])
        return (color: Self.unpack(packed), packed: packed)
    }
}
