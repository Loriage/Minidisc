import UIKit
typealias PlatformImage = UIImage

import SwiftUI

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
