import CoreImage.CIFilterBuiltins
import UIKit

/// Serial worker with one reusable Core Image context. No image processing on the main actor.
actor ArtworkBandSampler {
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func sample(_ image: UIImage) -> [Int]? {
        guard !Task.isCancelled, image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 200 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(4, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.black.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            // Drawing the UIImage also applies its EXIF orientation.
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = thumbnail.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        let height = extent.height / 4
        var result: [Int] = []
        for index in 0..<4 {
            guard !Task.isCancelled else { return nil }
            let filter = CIFilter.areaAverage()
            filter.inputImage = input
            // Core Image starts at the bottom left; return bands in visual top-to-bottom order.
            filter.extent = CGRect(x: extent.minX, y: extent.maxY - CGFloat(index + 1) * height,
                                   width: extent.width, height: height)
            guard let output = filter.outputImage else { return nil }
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: colorSpace)
            result.append(Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2]))
        }
        return result
    }
}
