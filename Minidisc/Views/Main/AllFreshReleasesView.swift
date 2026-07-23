// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

// Architecture note — navigation regression guard:
// iOS uses NavigationLink(value:) + .navigationDestination(for: AlbumRecommendation.self)
// registered on this view. Do NOT switch to .navigationDestination(item:) or .sheet(item:) —
// state-driven item presentation produces duplicate-push bugs inside a pushed NavigationStack
// context. Do NOT pass a SwiftData @Model as the NavigationLink value; AlbumRecommendation
// is a plain struct and must remain so.

import SwiftUI

struct AllFreshReleasesView: View {
    @Environment(\.appContainer) private var container
    let vm: AllFreshReleasesViewModel

    @Namespace private var releaseZoomNamespace

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.groupedReleases.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Releases", systemImage: "sparkles")
                } description: {
                    Text("Nothing in the past 3 months from artists you listen to.")
                }
            } else {
                scrollContent
            }
        }
        .navigationTitle("Fresh Releases")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AlbumRecommendation.self) { release in
            FreshReleaseDetailView(
                release: release,
                providers: container?.externalProvidersStore.load() ?? []
            )
            .minidiscZoomTransition(
                sourceID: release.id ?? "\(release.artistName)-\(release.title)",
                in: releaseZoomNamespace
            )
        }
        .task { await vm.loadReleases() }
    }

    // MARK: - Scroll content

    @ViewBuilder
    private var scrollContent: some View {
        List {
            ForEach(vm.groupedReleases, id: \.month) { section in
                Section(Self.monthFormatter.string(from: section.month)) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, release in
                        NavigationLink(value: release) {
                            FreshReleaseRow(
                                release: release,
                                zoomSourceId: release.id ?? "\(release.artistName)-\(release.title)",
                                zoomNamespace: releaseZoomNamespace
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await vm.loadReleases() }
    }

    // MARK: - iOS row

    private struct FreshReleaseRow: View {
        let release: AlbumRecommendation
        var zoomSourceId: String? = nil
        var zoomNamespace: Namespace.ID? = nil

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return f
        }()

        var body: some View {
            HStack(spacing: MinidiscSpacing.m) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ExternalCoverView(url: release.coverArtURL) {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .minidiscCoverStyle()
                    .frame(width: 52, height: 52)
                    .minidiscMatchedTransitionSource(id: zoomSourceId, in: zoomNamespace)

                VStack(alignment: .leading, spacing: 2) {
                    Text(release.title)
                        .font(.minidiscCellTitle)
                        .lineLimit(1)
                    Text(release.artistName)
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let date = release.releaseDate {
                        Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                            .font(.minidiscCaption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}
