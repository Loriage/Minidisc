import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit

actor AnimatedArtwork {
    nonisolated static let maximumSourceByteCount = 100 * 1024 * 1024

    nonisolated enum AspectRatio: Hashable, Sendable {
        case square
        case portrait
    }

    nonisolated let id: String
    nonisolated let previewData: Data
    nonisolated let isPortrait: Bool
    private let source: Source
    private var videoTask: Task<VideoFile?, Never>?

    private init(source: Source) {
        self.source = source
        id = source.id
        previewData = source.previewData
        isPortrait = source.width * 4 == source.height * 3
    }

    nonisolated static func prepare(
        _ data: Data,
        supportedAspectRatios: Set<AspectRatio> = [.square, .portrait]
    ) async -> AnimatedArtwork? {
        await Task.detached(priority: .utility) {
            guard let source = Source(data: data, supportedAspectRatios: supportedAspectRatios) else { return nil }
            return AnimatedArtwork(source: source)
        }.value
    }

    func videoURL() async -> URL? {
        if let videoTask { return await videoTask.value?.url }
        let source = source
        let task = Task.detached(priority: .utility) {
            try? await source.render()
        }
        videoTask = task
        return await task.value?.url
    }

    private nonisolated final class VideoFile: Sendable {
        let url: URL

        init(url: URL) { self.url = url }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated struct Source: Sendable {
        let data: Data
        let id: String
        let previewData: Data
        let width: Int
        let height: Int
        let delays: [Double]

        init?(data: Data, supportedAspectRatios: Set<AspectRatio>) {
            guard data.count <= AnimatedArtwork.maximumSourceByteCount,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  ["com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type),
                  (2...1800).contains(CGImageSourceGetCount(source)),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
                  sourceWidth > 0, sourceHeight > 0,
                  sourceWidth <= 8192, sourceHeight <= 8192,
                  sourceWidth == sourceHeight || sourceWidth * 4 == sourceHeight * 3
            else { return nil }

            let nativeAspectRatio: AspectRatio = sourceWidth == sourceHeight ? .square : .portrait
            guard let aspectRatio = [nativeAspectRatio, .portrait, .square]
                .first(where: supportedAspectRatios.contains) else { return nil }
            // H.264 requires even dimensions; preserve the advertised aspect ratio exactly.
            let unit = aspectRatio == .square ? 2 : 6
            let maxWidth = aspectRatio == .square ? 1200 : 900
            let width = max(unit, min(sourceWidth, maxWidth) / unit * unit)
            let height = aspectRatio == .square ? width : width * 4 / 3
            var delays: [Double] = []
            for index in 0..<CGImageSourceGetCount(source) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                else { return nil }
                let formats: [(CFString, CFString, CFString)] = [
                    (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                    (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
                    (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
                ]
                let delay = formats.lazy.compactMap { container, unclamped, clamped -> Double? in
                    guard let values = properties[container] as? [CFString: Any] else { return nil }
                    return (values[unclamped] as? Double) ?? (values[clamped] as? Double)
                }.first ?? 0.1
                guard delay.isFinite, delay >= 0 else { return nil }
                delays.append(delay < 0.02 ? 0.1 : delay)
            }
            guard delays.reduce(0, +) <= 30,
                  let preview = Self.frame(source: source, index: 0, width: width, height: height),
                  let previewData = UIImage(cgImage: preview).pngData()
            else { return nil }
            self.data = data
            id = "animated-artwork-v2-\(width)x\(height)-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            self.previewData = previewData
            self.width = width
            self.height = height
            self.delays = delays
        }

        func render() async throws -> VideoFile {
            let file = VideoFile(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("minidisc-artwork-\(UUID().uuidString).mp4"))
            let writer = try AVAssetWriter(outputURL: file.url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ])
            guard writer.canAdd(input) else { throw URLError(.cannotCreateFile) }
            writer.add(input)
            guard writer.startWriting(),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { throw writer.error ?? URLError(.cannotDecodeContentData) }
            writer.startSession(atSourceTime: .zero)
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            var elapsed = 0.0
            do {
                for (index, delay) in delays.enumerated() {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        guard writer.status == .writing, ContinuousClock.now < deadline else {
                            throw writer.error ?? URLError(.timedOut)
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                    let appended = autoreleasepool {
                        guard let pool = adaptor.pixelBufferPool else { return false }
                        var buffer: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                              let buffer,
                              let image = Self.frame(source: source, index: index, width: width, height: height)
                        else { return false }
                        CVBufferSetAttachments(buffer, [
                            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_sRGB,
                            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        ] as CFDictionary, .shouldPropagate)
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let context = CGContext(
                            data: CVPixelBufferGetBaseAddress(buffer),
                            width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        ) else { return false }
                        context.setFillColor(UIColor.black.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                        return adaptor.append(buffer,
                            withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 600))
                    }
                    guard appended else { throw writer.error ?? URLError(.cannotDecodeContentData) }
                    elapsed += delay
                }
                writer.endSession(atSourceTime: CMTime(seconds: elapsed, preferredTimescale: 600))
                input.markAsFinished()
                await writer.finishWriting()
                guard writer.status == .completed else {
                    throw writer.error ?? URLError(.cannotWriteToFile)
                }
                return file
            } catch {
                writer.cancelWriting()
                throw error
            }
        }

        private static func frame(source: CGImageSource, index: Int, width: Int, height: Int) -> CGImage? {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary),
            let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let imageWidth = CGFloat(image.width) * scale
            let imageHeight = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(
                x: (CGFloat(width) - imageWidth) / 2,
                y: (CGFloat(height) - imageHeight) / 2,
                width: imageWidth, height: imageHeight
            ))
            return context.makeImage()
        }
    }
}
