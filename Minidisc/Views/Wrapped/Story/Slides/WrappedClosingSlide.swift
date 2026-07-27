import SwiftUI

struct WrappedClosingSlide: View {
    let year: Int
    let data: WrappedData
    let palette: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            MeshGradientBackground(palette: palette, animated: !reduceMotion)

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: MinidiscSpacing.m) {
                    Image(systemName: "waveform")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(.white)

                    Text("Thanks for\nlistening.")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .kerning(-1)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Your \(year) Wrapped")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer(minLength: MinidiscSpacing.xl)

                HStack(spacing: MinidiscSpacing.m) {
                    statCard(value: data.totalSecondsListened.wrappedCompactLabel(), label: String(localized: "listened"))
                    statCard(value: "\(data.totalTracksPlayed)", label: data.totalTracksPlayed == 1 ? String(localized: "play") : String(localized: "plays"))
                    statCard(value: "\(data.totalUniqueArtists)", label: data.totalUniqueArtists == 1 ? String(localized: "artist") : String(localized: "artists"))
                }
                .padding(.horizontal, MinidiscSpacing.xl)

                Spacer(minLength: MinidiscSpacing.l)

                // Space reserved for the share button overlay rendered by WrappedStoryPlayerView
                Spacer(minLength: MinidiscSpacing.xxxxl)

                Spacer()
            }
            .wrappedSlideEntrance()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stat card

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: MinidiscSpacing.xs) {
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .kerning(-0.5)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MinidiscSpacing.m)
        .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
    }
}
