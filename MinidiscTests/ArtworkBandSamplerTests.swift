import SwiftUI
import Testing
@testable import Minidisc

@MainActor
@Suite("Player artwork background")
struct ArtworkBandSamplerTests {
    @Test func bandsFollowVisualImageOrder() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).image { context in
            for (index, color) in [UIColor.red, .green, .blue, .white].enumerated() {
                color.setFill()
                context.fill(CGRect(x: 0, y: index * 20, width: 40, height: 20))
            }
        }
        let bands = try #require(await ArtworkBandSampler().sample(image))
        #expect(bands == [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF])
        let flipped = UIImage(cgImage: try #require(image.cgImage), scale: 1, orientation: .down)
        let flippedBands = try #require(await ArtworkBandSampler().sample(flipped))
        #expect(flippedBands == bands.reversed())
    }

    @Test func brightAndNeutralArtworkKeepsSecondaryTextReadable() throws {
        let samples: [Color] = [.white, .yellow, .cyan, .gray, .red, .green, .blue, .black]
        for color in PlayerBackgroundPalette.colors(from: samples) {
            let rgb = try #require(color.rgbComponents)
            let bg = PlayerBackgroundPalette.luminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
            let text = PlayerBackgroundPalette.luminance(red: 0.7 + rgb.red * 0.3,
                                                       green: 0.7 + rgb.green * 0.3,
                                                       blue: 0.7 + rgb.blue * 0.3)
            #expect((text + 0.05) / (bg + 0.05) >= 4.5)
        }
        let neutralGray = Color(red: 0.5, green: 0.5, blue: 0.5)
        let gray = try #require(PlayerBackgroundPalette.colors(from: [neutralGray]).first?.rgbComponents)
        #expect(abs(gray.red - gray.green) < 0.001)
        #expect(abs(gray.green - gray.blue) < 0.001)
    }

    @Test func palettesAreCachedInvalidatedAndRespectManualColors() async throws {
        let extractor = DominantColorExtractor()
        let id = UUID().uuidString
        defer { extractor.setColorOverride(nil, forIds: [id]); extractor.invalidate(for: id) }
        func image(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        let red = try #require(await extractor.backgroundColors(for: id, image: image(.red)))
        #expect(await extractor.backgroundColors(for: id, image: image(.blue)) == red)
        extractor.invalidate(for: id)
        #expect(extractor.cachedBackgroundColors(for: id) == nil)
        let blue = try #require(await extractor.backgroundColors(for: id, image: image(.blue)))
        #expect(blue != red)
        extractor.setColorOverride(.green, forIds: [id])
        #expect(extractor.cachedBackgroundColors(for: id) == Array(repeating: Color.green, count: 4))
        extractor.setColorOverride(nil, forIds: [id])
        #expect(extractor.cachedBackgroundColors(for: id) == blue)
        extractor.clearCache()
        #expect(extractor.cachedBackgroundColors(for: id) == nil)
    }
}
