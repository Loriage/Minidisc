import Accessibility
import AVFoundation
import SwiftUI

struct PlayerArtworkView: View {
    let id: String
    let isPlaying: Bool
    let animationEnabled: Bool
    var initialImage: PlatformImage?

    @Environment(ArtworkImageCache.self) private var artworkCache
    @Environment(\.appContainer) private var container
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("coverArtUploadVersion") private var coverArtUploadVersion = 0
    @State private var animatedImagesEnabled = AccessibilitySettings.animatedImagesEnabled
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var video: Video?

    private struct Video {
        let coverID: String
        let artwork: AnimatedArtwork
        let url: URL
    }

    private var canAnimate: Bool {
        animationEnabled && scenePhase == .active && !reduceMotion && animatedImagesEnabled && !lowPowerMode
    }

    var body: some View {
        CoverArtView(id: id, size: 1000, initialImage: initialImage)
            .overlay {
                if canAnimate, let video, video.coverID == id {
                    AnimatedArtworkVideo(artwork: video.artwork, url: video.url, isPlaying: isPlaying)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: "\(id):\(artworkCache.quality.rawValue):\(coverArtUploadVersion):\(container?.serverState.isOnline ?? true):\(canAnimate)") {
                video = nil
                guard canAnimate,
                      let artwork = await artworkCache.animatedArtwork(for: id),
                      !Task.isCancelled,
                      let url = await artwork.videoURL(), !Task.isCancelled else { return }
                video = Video(coverID: id, artwork: artwork, url: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: AccessibilitySettings.animatedImagesEnabledDidChangeNotification)) { _ in
                animatedImagesEnabled = AccessibilitySettings.animatedImagesEnabled
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

private struct AnimatedArtworkVideo: UIViewRepresentable {
    let artwork: AnimatedArtwork
    let url: URL
    let isPlaying: Bool

    func makeUIView(context: Context) -> ArtworkVideoView { ArtworkVideoView() }

    func updateUIView(_ view: ArtworkVideoView, context: Context) {
        view.update(artwork: artwork, url: url, isPlaying: isPlaying)
    }

    static func dismantleUIView(_ view: ArtworkVideoView, coordinator: ()) {
        view.stop()
    }
}

final class ArtworkVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var sourceURL: URL?
    private var artwork: AnimatedArtwork?
    private var readiness: NSKeyValueObservation?

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .clear
        alpha = 0
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = player
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                alpha = playerLayer.isReadyForDisplay ? 1 : 0
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(artwork: AnimatedArtwork, url: URL, isPlaying: Bool) {
        if sourceURL != url {
            stop()
            self.artwork = artwork
            sourceURL = url
            playerLayer.player = player
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        if isPlaying { player.play() } else { player.pause() }
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        playerLayer.player = nil
        sourceURL = nil
        artwork = nil
        alpha = 0
    }
}
