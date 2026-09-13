import SwiftUI

struct CoverArtCard: View {
    let id: String
    let size: CGFloat
    /// Overrides size-based tier selection, for example when small cards need hero-resolution artwork.
    var tier: ArtworkTier? = nil
    var cornerRadius: CGFloat = MinidiscCornerRadius.standard
    var placeholderSystemImage: String = "music.note"
    var initialImage: PlatformImage? = nil

    var body: some View {
        CoverArtView(id: id, size: Int(size * 2), tier: tier, cornerRadius: cornerRadius, placeholderSystemImage: placeholderSystemImage, initialImage: initialImage)  // 2× for @2x sharpness
            .frame(width: size, height: size)
            .minidiscCoverStyle(cornerRadius: cornerRadius)
    }
}

#Preview("Light") {
    HStack(spacing: MinidiscSpacing.l) {
        CoverArtCard(id: "preview-small", size: 44)
        CoverArtCard(id: "preview-medium", size: 60)
        CoverArtCard(id: "preview-large", size: 160, cornerRadius: MinidiscCornerRadius.large)
    }
    .padding()
}

#Preview("Dark") {
    HStack(spacing: MinidiscSpacing.l) {
        CoverArtCard(id: "preview-small", size: 44)
        CoverArtCard(id: "preview-medium", size: 60)
        CoverArtCard(id: "preview-large", size: 160, cornerRadius: MinidiscCornerRadius.large)
    }
    .padding()
    .preferredColorScheme(.dark)
}
