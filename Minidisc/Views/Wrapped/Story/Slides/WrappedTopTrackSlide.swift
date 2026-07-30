import SwiftUI

struct WrappedTopTrackSlide: View {
    let data: WrappedData
    let palette: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var topTrack: TopTrackEntry? { data.topTracks.first }

    var body: some View {
        ZStack {
            MeshGradientBackground(palette: palette, animated: !reduceMotion)

            VStack(spacing: 0) {
                Spacer(minLength: MinidiscSpacing.xxxxl)

                Text("YOUR #1 TRACK")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                if let track = topTrack {
                    CoverArtCard(id: track.trackId, size: 300, cornerRadius: MinidiscCornerRadius.large)

                    Spacer(minLength: MinidiscSpacing.xl)

                    VStack(spacing: MinidiscSpacing.xs) {
                        Text(track.title)
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .kerning(-0.5)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)

                        Text(track.artistName)
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, MinidiscSpacing.xl)

                    Spacer(minLength: MinidiscSpacing.l)

                    Text(track.playCount.plural("play", "plays"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, MinidiscSpacing.m)
                        .padding(.vertical, MinidiscSpacing.s)
                        .background(Color.white.opacity(0.2), in: Capsule())
                } else {
                    Text("No track data yet")
                        .font(.system(.title2, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }
            .wrappedSlideEntrance()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
