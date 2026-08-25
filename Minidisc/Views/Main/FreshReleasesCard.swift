import SwiftUI

/// Horizontal scroll card showing personalized fresh releases from ListenBrainz.
/// Shows an empty state when releases are unavailable instead of collapsing.
struct FreshReleasesCard: View {
    private let cellWidth: CGFloat = 140

    let releases: [AlbumRecommendation]
    let isLoading: Bool
    let isListenBrainzConnected: Bool
    let onSeeAll: () -> Void
    /// Namespace for zoom matched-transition source on each cell.
    var zoomNamespace: Namespace.ID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            freshReleasesHeader

            if isLoading {
                skeletonScroll
            } else if !releases.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: MinidiscSpacing.s) {
                        ForEach(releases, id: \.self) { release in
                            FreshReleaseAlbumCell(
                                release: release,
                                zoomSourceId: release.id ?? "\(release.artistName)-\(release.title)",
                                zoomNamespace: zoomNamespace
                            )
                            .frame(width: cellWidth)
                        }
                        FreshReleasesSeeAllCell(onSeeAll: onSeeAll)
                            .frame(width: cellWidth)
                    }
                    .padding(.horizontal, MinidiscSpacing.m)
                }
            } else if !isListenBrainzConnected {
                emptyStatePlaceholder(
                    icon: "waveform.circle",
                    message: "Connect ListenBrainz in Settings to discover fresh releases based on your listening history."
                )
            } else {
                emptyStatePlaceholder(
                    icon: "music.note.list",
                    message: "No fresh releases found based on your recent listening history."
                )
            }
        }
    }

    @ViewBuilder
    private var freshReleasesHeader: some View {
        if releases.isEmpty {
            MinidiscCarouselHeader(
                "Fresh Releases",
                showsChevron: false,
                horizontalPadding: MinidiscSpacing.m
            )
            .accessibilityAddTraits(.isHeader)
        } else {
            Button(action: onSeeAll) {
                MinidiscCarouselHeader(
                    "Fresh Releases",
                    showsChevron: true,
                    horizontalPadding: MinidiscSpacing.m
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fresh Releases")
            .accessibilityHint("See all")
        }
    }

    private func emptyStatePlaceholder(icon: String, message: LocalizedStringKey) -> some View {
        VStack(spacing: MinidiscSpacing.s) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 168)
        .padding(.horizontal, MinidiscSpacing.m)
    }

    private var skeletonScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: MinidiscSpacing.s) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                        SkeletonBlock(width: 140, height: 140, cornerRadius: MinidiscCornerRadius.standard)
                        SkeletonBlock(width: 110, height: 12)
                        SkeletonBlock(width: 80, height: 10)
                    }
                    .frame(width: 140)
                }
            }
            .padding(.horizontal, MinidiscSpacing.m)
        }
        .allowsHitTesting(false)
    }
}

private struct FreshReleasesSeeAllCell: View {
    let onSeeAll: () -> Void

    var body: some View {
        Button(action: onSeeAll) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous)
                                .fill(Color.minidiscAccent.opacity(0.08))
                            Image(systemName: "chevron.forward")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Color.minidiscAccent)
                                .frame(width: 44, height: 44)
                        }
                    }
                Text("Past 90 days")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all")
        .accessibilityHint("Past 90 days")
    }
}

// MARK: - Cell

struct FreshReleaseAlbumCell: View {
    let release: AlbumRecommendation
    /// Zoom matched-transition source ID.
    var zoomSourceId: String? = nil
    /// Zoom matched-transition namespace.
    var zoomNamespace: Namespace.ID? = nil

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        NavigationLink(value: release) {
            cellContent
        }
        .buttonStyle(.plain)
        .minidiscMatchedTransitionSource(id: zoomSourceId, in: zoomNamespace)
    }

    private var cellContent: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ExternalCoverView(url: release.coverArtURL) {
                        Color.secondary.opacity(0.2)
                    }
                }
                .minidiscCoverStyle()

            CoverCardMetadata(
                title: release.title,
                subtitle: release.artistName,
                detail: release.releaseDate.map {
                    Self.relativeFormatter.localizedString(for: $0, relativeTo: Date())
                }
            )
        }
    }
}
