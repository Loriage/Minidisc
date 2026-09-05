import SwiftUI

struct ArtistStationCard: View {
    let station: ArtistStation
    let isStarting: Bool
    let onPlay: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var side: CGFloat { dynamicTypeSize.isAccessibilitySize ? 260 : 160 }
    private var palette: [Color] {
        switch station.id.utf8.reduce(0, { ($0 + Int($1)) % 3 }) {
        case 0: [Color(red: 0.26, green: 0.12, blue: 0.34), Color(red: 0.72, green: 0.30, blue: 0.38)]
        case 1: [Color(red: 0.10, green: 0.24, blue: 0.34), Color(red: 0.18, green: 0.55, blue: 0.62)]
        default: [Color(red: 0.35, green: 0.12, blue: 0.10), Color(red: 0.82, green: 0.25, blue: 0.13)]
        }
    }

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                        .padding(side * 0.10).offset(x: side * 0.30, y: side * 0.24)
                    FeaturedArtistAvatar(artist: station.artist, size: side * 0.72)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(side * 0.09)
                    ZStack {
                        Circle().fill(.black.opacity(0.75))
                        if isStarting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .padding(12)
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
                .accessibilityHidden(true)
                CoverCardMetadata(title: String(localized: "\(station.artist.name) & Similar Artists"),
                                  subtitle: String(localized: "Artist Station"))
            }
            .frame(width: side, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(station.artist.name) & Similar Artists"))
        .accessibilityHint("Play an artist station")
        .accessibilityValue(isStarting ? Text("Loading") : Text(""))
        .accessibilityIdentifier("discover.station.\(station.id)")
    }
}

struct SmartShuffleCard: View {
    let coverIDs: [String]
    let isStarting: Bool
    let onPlay: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: MinidiscSpacing.m) {
                VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                    Label("Smart Shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Rediscover Your Library")
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A new mix, every time")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: MinidiscSpacing.s) {
                        if isStarting { ProgressView().tint(.white) }
                        Label(isStarting ? LocalizedStringResource("Preparing…") : LocalizedStringResource("Shuffle"),
                              systemImage: "play.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, MinidiscSpacing.m)
                    .frame(minHeight: 44)
                    .background(.white.opacity(0.18), in: Capsule())
                    .padding(.top, MinidiscSpacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    ShuffleArtwork(coverIDs: coverIDs)
                        .frame(width: 104, height: 132)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .padding(MinidiscSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(red: 0.48, green: 0.06, blue: 0.18),
                                                 Color(red: 0.80, green: 0.17, blue: 0.08)],
                                       startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Smart Shuffle")
        .accessibilityHint("Play a new mix from your library")
        .accessibilityValue(isStarting ? Text("Preparing…") : Text(""))
        .accessibilityIdentifier("discover.smartShuffle")
        .padding(.horizontal, MinidiscSpacing.l)
    }
}

private struct ShuffleArtwork: View {
    let coverIDs: [String]

    var body: some View {
        ZStack {
            if coverIDs.isEmpty {
                Image(systemName: "shuffle")
                    .font(.system(size: 60, weight: .bold))
                    .rotationEffect(.degrees(-12))
            } else {
                ForEach(Array(coverIDs.prefix(3).enumerated()), id: \.element) { index, id in
                    CoverArtView(id: id, size: 180)
                        .frame(width: 78, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        .rotationEffect(.degrees(Double(index - 1) * 12))
                        .offset(x: CGFloat(index - 1) * 10, y: CGFloat(index - 1) * 24)
                }
            }
        }
    }
}
