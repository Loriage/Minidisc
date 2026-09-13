import SwiftUI
import SwiftSonic
import OSLog

struct RadioCard: View {
    let station: InternetRadioStation

    @Environment(\.appContainer) private var container

    var body: some View {
        Button {
            Task { await play() }
        } label: {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                cardBackground
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
                CoverCardMetadata(title: station.name)
            }
            .frame(width: 140, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(station.name)")
    }

    @ViewBuilder
    private var cardBackground: some View {
        if let coverArt = station.coverArt, !coverArt.isEmpty {
            ZStack {
                Color.black
                CoverArtCard(id: coverArt, size: 140)
            }
            .frame(width: 140, height: 140)
            .clipped()
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.161, green: 0.475, blue: 1.0),
                    Color(red: 0.000, green: 0.588, blue: 0.533)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    private func play() async {
        guard let container else { return }
        HapticFeedback.medium.trigger()
        do {
            try await container.playerService.playRadio(station)
        } catch {
            Logger.radio.error("RadioCard: playRadio failed — \(error)")
        }
    }
}
