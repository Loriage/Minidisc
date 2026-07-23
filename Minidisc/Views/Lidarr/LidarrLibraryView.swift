// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// The Lidarr tab: a grid of the artists Lidarr manages, with a button to search and add more.
struct LidarrLibraryView: View {
    @Environment(\.appContainer) private var container

    @State private var artists: [LidarrArtist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var client: LidarrClient?
    @State private var showSearch = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MinidiscSpacing.m)]

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't Load Lidarr",
                    subtitle: LocalizedStringKey(errorMessage),
                    action: .init(label: "Retry") { Task { await load() } }
                )
            } else if artists.isEmpty {
                EmptyStateView(
                    systemImage: "music.mic",
                    title: "No Artists Yet",
                    subtitle: "Tap + to search Lidarr and add an artist."
                )
            } else {
                grid
            }
        }
        .navigationTitle("Lidarr")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: LidarrQueueRoute()) {
                    Image(systemName: "waveform.path.ecg")
                }
                .tint(.primary)
                .accessibilityLabel("Activity")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSearch = true } label: { Image(systemName: "plus") }
                    .tint(.primary)
                    .accessibilityLabel("Add Artist")
            }
        }
        .sheet(isPresented: $showSearch, onDismiss: { Task { await load() } }) {
            LidarrArtistSearchView()
        }
        .navigationDestination(for: LidarrArtist.self) { artist in
            if let client {
                LidarrArtistDetailView(artist: artist, client: client)
            }
        }
        .navigationDestination(for: LidarrInteractiveSearchRoute.self) { route in
            if let client {
                LidarrInteractiveSearchView(scope: route.scope, client: client)
            }
        }
        .navigationDestination(for: LidarrQueueRoute.self) { _ in
            if let client {
                LidarrQueueView(client: client)
            }
        }
        .task {
            if client == nil { client = await container?.lidarrSettings.makeClient() }
            await load()
        }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .lidarrLibraryDidChange)) { _ in
            Task { await load() }
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: MinidiscSpacing.l) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            if let client {
                                LidarrArtistCell(artist: artist, client: client)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(artist.id)
                    }
                }
                .padding(MinidiscSpacing.l)
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                let letters = artists.availableAlphabetLetters(keyPath: \.artistName)
                if letters.count >= 5 {
                    AlphabetJumpBar(
                        availableLetters: letters,
                        onLetterTap: { letter in
                            if let id = firstAlphabetItemID(forLetter: letter, in: artists, keyPath: \.artistName) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                    )
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private func load() async {
        if client == nil { client = await container?.lidarrSettings.makeClient() }
        guard let client else {
            isLoading = false
            errorMessage = String(localized: "Lidarr is not connected.")
            return
        }
        errorMessage = nil
        do {
            let fetched = try await client.artists()
            artists = fetched.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = (error as? LidarrError).map(Self.message(for:)) ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    static func message(for error: LidarrError) -> String {
        switch error {
        case .unauthorized: return String(localized: "The API key was rejected.")
        case .htmlResponse: return String(localized: "A reverse proxy is blocking the request.")
        case .cancelled: return ""
        case .badURL: return String(localized: "The Lidarr address is not valid.")
        case .transport(let d), .decoding(let d): return d
        }
    }
}

// MARK: - Artist cell

private struct LidarrArtistCell: View {
    let artist: LidarrArtist
    let client: LidarrClient

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            LidarrCoverImage(path: artist.posterPath, client: client) {
                RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay { Image(systemName: "music.mic").font(.title).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
            .overlay(alignment: .topTrailing) {
                if !artist.monitored {
                    Image(systemName: "bookmark.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.4))
                        .padding(MinidiscSpacing.xs)
                }
            }

            Text(artist.artistName)
                .font(.minidiscCaption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(artist.statistics?.albumCount == 1 ? "1 album" : "\(artist.statistics?.albumCount ?? 0) albums")
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
