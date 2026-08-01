import CoreGraphics
import MediaPlayer
import Testing
import UIKit
@testable import Minidisc

private nonisolated struct SendableMediaArtwork: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
    let expectedImage: UIImage
}

@Suite("Now Playing artwork concurrency")
struct NowPlayingCenterPresenterConcurrencyTests {
    @Test("MediaPlayer may request artwork away from MainActor")
    @MainActor
    func requestHandlerIsNonisolated() async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let box = SendableMediaArtwork(
            artwork: NowPlayingCenterPresenter.makeArtwork(image: image),
            expectedImage: image
        )

        let returnedExpectedSnapshot = await Task.detached {
            box.artwork.image(at: CGSize(width: 64, height: 64)) === box.expectedImage
        }.value

        #expect(returnedExpectedSnapshot)
    }
}
