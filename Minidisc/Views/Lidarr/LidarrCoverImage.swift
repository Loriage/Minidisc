import SwiftUI
import UIKit

@MainActor
final class LidarrImageStore {
    static let shared = LidarrImageStore()
    private var images: [String: UIImage] = [:]

    func image(for key: String) -> UIImage? { images[key] }
    func store(_ image: UIImage, for key: String) { images[key] = image }
}

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
