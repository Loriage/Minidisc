import AVFoundation
import ImageIO
import MediaPlayer
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Minidisc

@Suite("Animated Lock Screen artwork", .serialized)
@MainActor
struct AnimatedArtworkTests {
    @Test(arguments: ["gif", "apng", "webp"])
    func convertsFramesAndTimingToPlayableVideo(format: String) async throws {
        let data = try fixture(format: format)
        let artwork = try #require(await AnimatedArtwork.prepare(data))
        async let firstURL = artwork.videoURL()
        async let secondURL = artwork.videoURL()
        let urls = await (firstURL, secondURL)
        let url = try #require(urls.0)
        #expect(urls.1 == url)
        #expect(url.isFileURL)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 0.7) < 0.03)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 24, height: 24))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        let second = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        #expect(pixel(first).red > 200)
        #expect(pixel(first).blue < 40)
        #expect(pixel(second).blue > 200)
        #expect(pixel(second).red < 40)
    }

    @Test func keepsPortraitAspectRatioAndStaticPreview() async throws {
        let artwork = try #require(await AnimatedArtwork.prepare(fixture(format: "gif", width: 18, height: 24)))
        #expect(artwork.isPortrait)
        let preview = try #require(UIImage(data: artwork.previewData)?.cgImage)
        #expect(preview.width * 4 == preview.height * 3)
        let url = try #require(await artwork.videoURL())
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 18, height: 24))
    }

    @Test func fitsSquareArtworkInsideSupportedPortraitFormat() async throws {
        let data = try fixture(format: "gif")
        let square = try #require(await AnimatedArtwork.prepare(data))
        let portrait = try #require(await AnimatedArtwork.prepare(data, supportedAspectRatios: [.portrait]))
        #expect(portrait.isPortrait)
        #expect(portrait.id != square.id)
        let preview = try #require(UIImage(data: portrait.previewData)?.cgImage)
        #expect(preview.width == 24 && preview.height == 32)
        let center = try #require(preview.cropping(to: CGRect(x: 0, y: 4, width: 24, height: 24)))
        let padding = try #require(preview.cropping(to: CGRect(x: 0, y: 0, width: 24, height: 4)))
        #expect(pixel(center).red > 200)
        #expect(pixel(padding).red < 5)
        let url = try #require(await portrait.videoURL())
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 24, height: 32))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let videoCenter = try #require(frame.cropping(to: CGRect(x: 0, y: 4, width: 24, height: 24)))
        #expect(pixel(videoCenter).blue > 200)
        #expect(await AnimatedArtwork.prepare(data, supportedAspectRatios: []) == nil)
    }

    @Test func fallsBackForStaticInvalidOrUnsupportedArtwork() async throws {
        #expect(await AnimatedArtwork.prepare(Data("not an image".utf8)) == nil)
        let staticData = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
            .pngData { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 24, height: 24)) }
        #expect(await AnimatedArtwork.prepare(staticData) == nil)
        #expect(await AnimatedArtwork.prepare(try fixture(format: "gif", width: 48, height: 24)) == nil)
        #expect(await AnimatedArtwork.prepare(try fixture(format: "gif", delays: [20, 20])) == nil)
    }

    @Test func memoryOnlyArtworkReusesTheDownloadedSource() async throws {
        var paddedData = try fixture(format: "gif")
        paddedData.count = 100 * 1024 * 1024
        let data = paddedData
        #expect(await AnimatedArtwork.prepare(data) != nil)
        var oversized = data
        oversized.append(0)
        #expect(await AnimatedArtwork.prepare(oversized) == nil)
        oversized = Data()
        let requests = RequestCounter()
        let cache = ArtworkImageCache(
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            dataLoader: { request in
                await requests.record()
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            imageDecoder: { data, pixels in ArtworkImageCache.thumbnailImage(from: data, maxDimension: pixels) }
        )
        cache.persistCoversEnabled = false
        #expect(await cache.load(coverArtId: "album", tier: .hero) != nil)
        #expect(await cache.animationSourceData(for: "album") == data)
        #expect(await requests.count == 1)
        cache.clearCache()
        cache.networkAccessAllowed = { false }
        #expect(await cache.animationSourceData(for: "album") == nil)
        #expect(await requests.count == 1)
    }

    @Test func playerAndLockScreenShareAnimationUntilCoverInvalidation() async throws {
        let data = try fixture(format: "gif")
        let requests = RequestCounter()
        let cache = ArtworkImageCache(
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            dataLoader: { request in
                await requests.record()
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            imageDecoder: { data, pixels in ArtworkImageCache.thumbnailImage(from: data, maxDimension: pixels) }
        )
        cache.persistCoversEnabled = false
        async let lockScreen = cache.animatedArtwork(for: "cover")
        async let player = cache.animatedArtwork(for: "cover")
        let results = await (lockScreen, player)
        let first = try #require(results.0)
        #expect(first === results.1)
        #expect(await requests.count == 1)
        let video = try #require(await first.videoURL())
        #expect(await results.1?.videoURL() == video)
        await cache.invalidate(for: "cover")
        let refreshed = try #require(await cache.animatedArtwork(for: "cover"))
        #expect(refreshed !== first)
        #expect(await requests.count == 2)
        cache.clearCache()
        cache.networkAccessAllowed = { false }
        #expect(await cache.animatedArtwork(for: "cover") == nil)
    }

    @Test func decorativePlayerPausesAndReleasesItsVideo() async throws {
        let artwork = try #require(await AnimatedArtwork.prepare(fixture(format: "gif")))
        let url = try #require(await artwork.videoURL())
        let view = ArtworkVideoView()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.addSubview(view)
        view.frame = CGRect(x: 20, y: 100, width: 240, height: 240)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.stop()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        view.update(artwork: artwork, url: url, isPlaying: true)
        #expect(view.player.isMuted)
        #expect(!view.player.allowsExternalPlayback)
        #expect(!view.player.preventsDisplaySleepDuringVideoPlayback)
        #expect(view.player.audiovisualBackgroundPlaybackPolicy == .pauses)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (view.player.currentTime().seconds < 0.15 || (view.layer as? AVPlayerLayer)?.isReadyForDisplay != true),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((view.layer as? AVPlayerLayer)?.isReadyForDisplay == true)
        #expect(view.player.currentTime().seconds >= 0.15)
        view.update(artwork: artwork, url: url, isPlaying: false)
        #expect(view.player.rate == 0)
        let pausedTime = view.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(view.player.currentTime().seconds - pausedTime) < 0.03)
        view.stop()
        #expect(view.player.items().isEmpty)
        #expect((view.layer as? AVPlayerLayer)?.player == nil)
    }

    @Test func downloadedAnimationWorksOfflineAndIgnoresObsoleteTrackUpdates() async throws {
        let data = try fixture(format: "gif")
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try data.write(to: directory.appendingPathComponent("cover"))
        let cache = ArtworkImageCache(
            coverArtURLProvider: { _, _ in
                Issue.record("Offline artwork must not resolve a server URL")
                return nil
            },
            localCoverURLProvider: { id in
                let url = directory.appendingPathComponent(id)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            dataLoader: { _ in
                Issue.record("Offline artwork must not request the network")
                throw URLError(.notConnectedToInternet)
            },
            imageDecoder: { data, pixels in ArtworkImageCache.thumbnailImage(from: data, maxDimension: pixels) }
        )
        cache.networkAccessAllowed = { false }
        #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        let bytes = try #require(await cache.animationSourceData(for: "cover"))
        let artwork = try #require(await AnimatedArtwork.prepare(bytes))
        let presenter = NowPlayingCenterPresenter()
        defer { presenter.shutdown() }
        let service = NowPlayingService(playerService: MockPlayerService(),
            artworkImageCache: cache, presenter: presenter)
        await service.update(with: snapshot(id: "one"))
        let key = try #require(MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.first {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[$0] is MPMediaItemAnimatedArtwork
        })
        await service.pushPosition(elapsed: 15, rate: 1, duration: 180, songId: "one")
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)

        presenter.setBaseInfo(for: snapshot(id: "two"), generation: 2)
        presenter.setAnimatedArtwork(artwork, generation: 1)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[key] == nil)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "two")
        presenter.clear(generation: 3)
        presenter.setAnimatedArtwork(artwork, generation: 2)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    private func fixture(format: String, width: Int = 24, height: Int = 24,
                         delays: [Double] = [0.2, 0.5]) throws -> Data {
        if format == "webp" {
            // Two solid frames (red for 200 ms, blue for 500 ms), encoded with cwebp/webpmux.
            return try #require(Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAFwAAFwAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAABcAABcAAMgAAABWUDhMDwAAAC8XwAUABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAABcAABcAAPQBAABWUDhMDwAAAC8XwAUABxDR//4HIqL/AQA="))
        }
        let data = NSMutableData()
        let type = format == "gif" ? UTType.gif : UTType.png
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 2, nil))
        for (index, color) in [UIColor.red, .blue].enumerated() {
            let rendererFormat = UIGraphicsImageRendererFormat()
            rendererFormat.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: rendererFormat).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            let key = format == "gif" ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
            let delayKey = format == "gif" ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
            CGImageDestinationAddImage(destination, try #require(image.cgImage), [key: [delayKey: delays[index]]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixel(_ image: CGImage) -> (red: UInt8, blue: UInt8) {
        var bytes: [UInt8] = [0, 0, 0, 0]
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (bytes[0], bytes[2])
    }

    private func snapshot(id: String) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: id, artist: "Artist", album: "Album", duration: 180,
            position: 0, playbackRate: 1, artworkURL: nil, artworkHeaders: [:],
            coverArtId: "cover", isLiveStream: false, radioStationName: nil, songId: id)
    }

    private actor RequestCounter {
        var count = 0
        func record() { count += 1 }
    }
}
