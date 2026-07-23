// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// What an interactive search covers: one album, or every monitored album of an artist. Lidarr serves
/// both from `GET /api/v1/release`, keyed by `albumId` or `artistId`.
enum LidarrReleaseScope: Hashable {
    case album(LidarrAlbum)
    case artist(LidarrArtist)
}

/// A pushed route to an interactive search. Wrapped in its own type so it does not collide with the
/// album- and artist-detail navigation destinations on the same stack.
struct LidarrInteractiveSearchRoute: Hashable {
    let scope: LidarrReleaseScope
}

/// Interactive search: lists the releases the indexers found for an album or artist. Tapping a release
/// opens its detail, where the user reads the rejection reasons and grabs it. Mirrors Ruddarr.
struct LidarrInteractiveSearchView: View {
    let scope: LidarrReleaseScope
    let client: LidarrClient

    @State private var releases: [LidarrRelease] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var sort: SortField = .weight
    @State private var selectedRelease: LidarrRelease?

    // Filters
    @State private var selectedIndexer: String?
    @State private var selectedQuality: String?
    @State private var approvedOnly = false
    @State private var freeleechOnly = false
    @State private var originalOnly = false

    enum SortField: String, CaseIterable, Identifiable {
        case weight, seeders, size, age
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weight:  return "Best match"
            case .seeders: return "Seeders"
            case .size:    return "File size"
            case .age:     return "Age"
            }
        }
        var systemImage: String {
            switch self {
            case .weight:  return "scalemass"
            case .seeders: return "person.2.wave.2"
            case .size:    return "externaldrive"
            case .age:     return "calendar"
            }
        }
    }

    private var indexers: [String] {
        Array(Set(releases.compactMap { $0.indexer })).sorted()
    }
    private var qualities: [String] {
        Array(Set(releases.compactMap { $0.qualityName })).sorted()
    }
    private var hasActiveFilter: Bool {
        selectedIndexer != nil || selectedQuality != nil || approvedOnly || freeleechOnly || originalOnly
    }

    private var filtered: [LidarrRelease] {
        var base = releases
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { base = base.filter { $0.title.localizedCaseInsensitiveContains(trimmed) } }
        if let indexer = selectedIndexer { base = base.filter { $0.indexer == indexer } }
        if let quality = selectedQuality { base = base.filter { $0.qualityName == quality } }
        if approvedOnly { base = base.filter { !$0.isRejected } }
        if freeleechOnly { base = base.filter { $0.isFreeleech } }
        if originalOnly { base = base.filter { $0.isOriginal } }
        switch sort {
        case .weight:  return base
        case .seeders: return base.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
        case .size:    return base.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .age:     return base.sorted { ($0.age ?? .max) < ($1.age ?? .max) }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: MinidiscSpacing.m) {
                    ProgressView()
                    Text("Searching…").font(.minidiscBody).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Search Failed", subtitle: LocalizedStringKey(errorMessage))
            } else if filtered.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass", title: "No Releases", subtitle: "No release matched this album.")
            } else {
                List(filtered) { release in
                    Button {
                        selectedRelease = release
                    } label: {
                        LidarrReleaseRow(release: release)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        .searchable(text: $query, prompt: "Filter releases")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortField.allCases) { field in
                            Label(field.label, systemImage: field.systemImage).tag(field)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
        }
        .sheet(item: $selectedRelease) { release in
            LidarrReleaseDetailView(release: release, client: client, scope: scope)
        }
        .task { await load() }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Indexer", selection: $selectedIndexer) {
                Text("All Indexers").tag(String?.none)
                ForEach(indexers, id: \.self) { indexer in
                    Text(indexer).tag(String?.some(indexer))
                }
            }
            Picker("Quality", selection: $selectedQuality) {
                Text("All Qualities").tag(String?.none)
                ForEach(qualities, id: \.self) { quality in
                    Text(quality).tag(String?.some(quality))
                }
            }
            Divider()
            Toggle(isOn: $approvedOnly) {
                Label("Approved only", systemImage: "checkmark.seal")
            }
            Toggle(isOn: $freeleechOnly) {
                Label("FreeLeech only", systemImage: "leaf")
            }
            Toggle(isOn: $originalOnly) {
                Label("Original only", systemImage: "seal")
            }
            if hasActiveFilter {
                Divider()
                Button(role: .destructive) {
                    selectedIndexer = nil
                    selectedQuality = nil
                    approvedOnly = false
                    freeleechOnly = false
                    originalOnly = false
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .tint(hasActiveFilter ? .minidiscAccent : .primary)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch scope {
            case .album(let album):   releases = try await client.releases(albumId: album.id)
            case .artist(let artist): releases = try await client.releases(artistId: artist.id)
            }
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = LidarrLibraryView.message(for: (error as? LidarrError) ?? .transport(error.localizedDescription))
            }
        }
        isLoading = false
    }
}

// MARK: - Release row

private struct LidarrReleaseRow: View {
    let release: LidarrRelease

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(release.title)
                    .font(.minidiscCellTitle)
                    .lineLimit(2)

                HStack(spacing: MinidiscSpacing.xs) {
                    if let quality = release.qualityName { Text(quality) }
                    if let size = release.size {
                        Text("·")
                        Text(LidarrFormat.size(size))
                    }
                    if let age = release.age {
                        Text("·")
                        Text(LidarrFormat.age(days: age))
                    }
                }
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)

                HStack(spacing: MinidiscSpacing.xs) {
                    Text(release.isTorrent ? "Torrent" : "Usenet")
                    if release.isTorrent, let seeders = release.seeders {
                        Text("(\(seeders))")
                            .foregroundStyle(seeders > 0 ? Color(.systemGreen) : .orange)
                    }
                    if let indexer = release.indexer {
                        Text("·")
                        Text(indexer)
                    }
                }
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            if release.isRejected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, MinidiscSpacing.xs)
    }
}
