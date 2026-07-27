import SwiftUI
import OSLog

struct FreshReleaseDetailView: View {
    let release: AlbumRecommendation
    let providers: [ExternalReleaseProvider]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MinidiscSpacing.l) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ExternalCoverView(url: release.coverArtURL) {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.large)
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                    Text(release.title)
                        .font(.title2.bold())

                    Text(release.artistName)
                        .font(.minidiscCellTitle)
                        .foregroundStyle(.secondary)

                    if let date = release.releaseDate {
                        Text(Self.dateFormatter.string(from: date))
                            .font(.minidiscCaption)
                            .foregroundStyle(.secondary)
                    }
                }

                externalLinksSection
            }
            .padding(MinidiscSpacing.l)
        }
        .navigationTitle(release.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            for provider in providers {
                if provider.buildURL(artistName: release.artistName, albumTitle: release.title) == nil {
                    Logger.integrations.warning("buildURL returned nil for provider '\(provider.name, privacy: .public)'")
                }
            }
        }
    }

    @ViewBuilder
    private var externalLinksSection: some View {
        if providers.isEmpty {
            if let id = release.id,
               let lbURL = URL(string: "https://listenbrainz.org/release-group/\(id)") {
                externalLinkButton(title: "View on ListenBrainz", url: lbURL)
            }
        } else {
            VStack(spacing: MinidiscSpacing.s) {
                ForEach(providers) { provider in
                    if let url = provider.buildURL(artistName: release.artistName, albumTitle: release.title) {
                        externalLinkButton(title: "View on \(provider.name)", url: url)
                    }
                }
            }
        }
    }

    private func externalLinkButton(title: String, url: URL) -> some View {
        Button {
            ExternalLinkOpener.open(url)
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .font(.minidiscCellTitle)
            .padding(MinidiscSpacing.m)
            .frame(maxWidth: .infinity)
            .background(Color.minidiscAccent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
            .foregroundStyle(Color.minidiscAccent)
        }
        .buttonStyle(.plain)
    }
}
