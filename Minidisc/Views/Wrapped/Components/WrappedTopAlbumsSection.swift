import SwiftUI

struct WrappedTopAlbumsSection: View {
    let albums: [TopAlbumEntry]

    private let columns = [
        GridItem(.flexible(), spacing: MinidiscSpacing.m),
        GridItem(.flexible(), spacing: MinidiscSpacing.m)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text("Top Albums")
                .font(.minidiscSectionTitle)
            if albums.isEmpty {
                emptyLabel("No album data for this period.")
            } else {
                LazyVGrid(columns: columns, spacing: MinidiscSpacing.m) {
                    ForEach(albums.prefix(6)) { album in
                        NavigationLink {
                            AlbumDetailView(albumId: album.albumId, albumName: album.title, coverArtId: album.albumId)
                        } label: {
                            albumCard(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func albumCard(_ album: TopAlbumEntry) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        CoverArtView(id: album.albumId, size: 220, tier: .hero)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
                    .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.standard)
                rankBadge(album.rank)
                    .padding(MinidiscSpacing.xs)
            }
            CoverCardMetadata(title: album.title, subtitle: album.artistName)
        }
    }

    private func medalColor(for rank: Int) -> Color {
        switch rank {
        case 1: return WrappedYearPalette.medalGold
        case 2: return WrappedYearPalette.medalSilver
        case 3: return WrappedYearPalette.medalBronze
        default: return MinidiscColors.accent
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        let isMedal = rank <= 3
        return Text("#\(rank)")
            .font(.minidiscCaption2)
            .fontWeight(.bold)
            .foregroundStyle(isMedal ? Color.black : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if isMedal {
                    Capsule().fill(medalColor(for: rank))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }

    private func emptyLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.minidiscCaption)
            .foregroundStyle(.secondary)
    }
}
