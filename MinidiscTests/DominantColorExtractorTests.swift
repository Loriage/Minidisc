import SwiftUI
import Testing
@testable import Minidisc

@MainActor
@Suite("Cover colour refresh")
struct DominantColorExtractorTests {
    @Test("Replacing a cover refreshes its bottom-edge colour as well as its dominant colour")
    func replacementInvalidatesBothSamples() throws {
        let extractor = DominantColorExtractor()
        let id = UUID().uuidString
        defer { extractor.invalidate(for: id) }

        let original = solidImage(.red)
        _ = extractor.dominantColor(for: id, image: original)
        _ = extractor.bottomStripColor(for: id, image: original)

        extractor.invalidate(for: id)
        #expect(extractor.cachedColor(for: id) == nil)
        #expect(extractor.bottomStripColor(for: id, image: nil) == .clear)

        let replacement = solidImage(.blue)
        let dominant = try #require(extractor.dominantColor(for: id, image: replacement).rgbComponents)
        let edge = try #require(extractor.bottomStripColor(for: id, image: replacement).rgbComponents)
        #expect(dominant.blue > dominant.red)
        #expect(edge.blue > edge.red)
    }

    @Test("Replacing a cover preserves an explicit theme override until it is reset")
    func replacementPreservesOverride() {
        let extractor = DominantColorExtractor()
        let id = UUID().uuidString
        defer {
            extractor.setColorOverride(nil, forIds: [id])
            extractor.invalidate(for: id)
        }

        extractor.setColorOverride(.green, forIds: [id])
        extractor.invalidate(for: id)
        #expect(extractor.bottomStripColor(for: id, image: solidImage(.blue)) == .green)

        extractor.setColorOverride(nil, forIds: [id])
        #expect(extractor.bottomStripColor(for: id, image: nil) == .clear)
        #expect(extractor.bottomStripColor(for: id, image: solidImage(.blue)) != .green)
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }
}
