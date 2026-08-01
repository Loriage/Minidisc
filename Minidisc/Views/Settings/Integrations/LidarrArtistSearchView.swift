import SwiftUI
import OSLog

/// Searches Lidarr for an artist and lets the user add it. Presented as a sheet from the Library tab.
struct LidarrArtistSearchView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [LidarrArtistLookup] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var client: LidarrClient?
    @State private var selected: LidarrArtistLookup?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MinidiscSpacing.m)]

    var body: some View {
        NavigationStack {
            Group {
                if client == nil {
                    EmptyStateView(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: "Lidarr Not Connected",
                        subtitle: "Connect Lidarr in Settings to add artists."
                    )
                } else if let errorMessage {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Search Failed",
                        subtitle: LocalizedStringKey(errorMessage)
                    )
                } else if isSearching {
                    LoadingStateView()
                } else if results.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: query.isEmpty ? "Find an Artist" : "No Results",
                        subtitle: query.isEmpty ? "Search Lidarr to add an artist to your collection." : "No artist matched your search."
                    )
                } else {
                    resultsGrid
                }
            }
            .navigationTitle("Add to Lidarr")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(.primary)
                }
            }
            .searchable(text: $query, prompt: "Artist name")
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
            .sheet(item: $selected) { artist in
                if let client {
                    LidarrAddArtistSheet(artist: artist, client: client) {
                        container?.toastService.showSuccess(String(localized: "Added to Lidarr"))
                        dismiss()
                    }
                }
            }
            .task {
                if client == nil { client = await container?.lidarrSettings.makeClient() }
            }
        }
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: MinidiscSpacing.l) {
                ForEach(results) { artist in
                    Button { selected = artist } label: {
                        LidarrArtistResultCell(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MinidiscSpacing.l)
        }
    }

    private func scheduleSearch(_ term: String) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ term: String) async {
        guard let client else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await client.searchArtists(term: term)
            guard !Task.isCancelled else { return }
            results = found
        } catch {
            // A newer keystroke cancelled this request — not an error to show.
            if Task.isCancelled { return }
            if let lidarr = error as? LidarrError {
                switch lidarr {
                case .cancelled: return
                case .unauthorized: errorMessage = String(localized: "The API key was rejected.")
                case .htmlResponse: errorMessage = String(localized: "A reverse proxy is blocking the request.")
                case .transport(let d), .decoding(let d): errorMessage = d
                case .badURL: errorMessage = String(localized: "The Lidarr address is not valid.")
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Result cell

private struct LidarrArtistResultCell: View {
    let artist: LidarrArtistLookup

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            AsyncImage(url: artist.posterURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay { Image(systemName: "music.mic").font(.title).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
            .overlay(alignment: .topTrailing) {
                if artist.isAlreadyAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color(.systemGreen))
                        .padding(MinidiscSpacing.xs)
                }
            }

            Text(artist.artistName)
                .font(.minidiscCaption)
                .fontWeight(.semibold)
                .lineLimit(1)
            if let disambiguation = artist.disambiguation, !disambiguation.isEmpty {
                Text(disambiguation)
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
