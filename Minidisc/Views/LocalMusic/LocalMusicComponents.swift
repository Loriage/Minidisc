import SwiftUI

struct LocalMusicGrid: View {
    let groups: [LocalMusicGroup]
    let category: LocalMusicCategory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 140), spacing: MinidiscSpacing.l)], spacing: MinidiscSpacing.l) {
            ForEach(groups) { group in
                NavigationLink {
                    LocalMusicCollectionView(group: group, category: category)
                } label: {
                    LocalMusicCard(group: group, category: category)
                }
                .buttonStyle(.plain)
                .id(group.scrollID)
            }
        }
    }
}

struct LocalMusicCard: View {
    let group: LocalMusicGroup
    let category: LocalMusicCategory
    var artworkSize: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            LocalMusicArtwork(id: group.artworkID, isArtist: category == .artists)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: artworkSize, height: artworkSize)
            if category == .artists {
                Text(group.name)
                    .font(.minidiscCellTitle)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                CoverCardMetadata(title: group.name, subtitle: group.tracks.first?.song.artist)
            }
        }
        .foregroundStyle(.primary)
    }
}

struct LocalMusicArtwork: View {
    let id: String
    var isArtist = false

    var body: some View {
        GeometryReader { geometry in
            CoverArtView(id: id, size: Int(geometry.size.width * 2), cornerRadius: 0)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipShape(RoundedRectangle(cornerRadius: isArtist ? geometry.size.width / 2 : MinidiscCornerRadius.standard))
        }
        .accessibilityHidden(true)
    }
}
