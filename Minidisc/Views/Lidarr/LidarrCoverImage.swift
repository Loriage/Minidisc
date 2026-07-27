// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import UIKit

/// In-memory cache for Lidarr cover images, keyed by their path, so a scroll does not re-fetch.
@MainActor
final class LidarrImageStore {
    static let shared = LidarrImageStore()
    private var images: [String: UIImage] = [:]

    func image(for key: String) -> UIImage? { images[key] }
    func store(_ image: UIImage, for key: String) { images[key] = image }
}

/// Loads a Lidarr cover through `LidarrClient` (so the API key and reverse-proxy headers are sent),
/// then displays it. Falls back to `placeholder` while loading or on failure.
struct LidarrCoverImage<Placeholder: View>: View {
    let path: String?
    let client: LidarrClient
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        image = nil
        guard let path else { return }
        if let cached = LidarrImageStore.shared.image(for: path) {
            image = cached
            return
        }
        guard let data = try? await client.imageData(forPath: path),
              let loaded = UIImage(data: data) else { return }
        LidarrImageStore.shared.store(loaded, for: path)
        image = loaded
    }
}
