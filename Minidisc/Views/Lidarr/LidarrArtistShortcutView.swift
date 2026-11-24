import SwiftUI

struct LidarrArtistShortcutView: View {
    let artist: SimilarArtistRecommendation

    @Environment(\.appContainer) private var container
    @State private var phase: Phase = .loading
    @State private var loadedRequest: RequestID?
    @State private var retry = 0
    @State private var showSearch = false
    @State private var showExisting = false

    private enum Phase {
        case loading
        case disconnected
        case ready(LidarrArtistResolution, LidarrClient)
        case failed(String)
    }

    private struct RequestID: Hashable {
        let artistID: String
        let mbid: String?
        let connectionRevision: Int?
        let retry: Int
    }

    private var requestID: RequestID {
        RequestID(artistID: artist.id, mbid: artist.mbid,
                  connectionRevision: container?.lidarrSettings.connectionRevision, retry: retry)
    }

    var body: some View {
        VStack(spacing: 0) {
            if loadedRequest != requestID {
                LoadingStateView()
            } else if showSearch {
                LidarrArtistSearchContent(query: artist.name)
            } else {
                switch phase {
                case .loading:
                    LoadingStateView()
                case .disconnected:
                    EmptyStateView(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: "Lidarr Not Connected",
                        subtitle: "Connect Lidarr in Settings to add artists."
                    )
                case .ready(.add(let result), let client):
                    LidarrAddArtistForm(artist: result, client: client) {
                        container?.toastService.showSuccess(String(localized: "Added to Lidarr"))
                    }
                case .ready(.existing, _):
                    ContentUnavailableView {
                        Label("Already in Lidarr", systemImage: "checkmark.circle")
                    } description: {
                        Text(artist.name)
                    } actions: {
                        Button("Open in Lidarr") { showExisting = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("lidarr.shortcut.open-existing")
                    }
                case .ready(.search, _), .ready(.notFound, _):
                    ContentUnavailableView {
                        Label("Artist Not Found", systemImage: "magnifyingglass")
                    } description: {
                        Text("No matching artist was found in Lidarr. You can search by name instead.")
                    } actions: {
                        Button("Search in Lidarr") { showSearch = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("lidarr.shortcut.search")
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Lidarr", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { retry += 1 }
                            .buttonStyle(.borderedProminent)
                        Button("Search in Lidarr") { showSearch = true }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("lidarr.shortcut.search")
                    }
                }
            }
        }
        .navigationTitle("Add to Lidarr")
        .navigationBarTitleDisplayModeInline()
        .navigationDestination(isPresented: $showExisting) {
            if case .ready(.existing(let existing), let client) = phase {
                LidarrArtistDetailView(artist: existing, client: client)
            }
        }
        .navigationDestination(for: LidarrInteractiveSearchRoute.self) { route in
            if case .ready(_, let client) = phase {
                LidarrInteractiveSearchView(scope: route.scope, client: client)
            }
        }
        .task(id: requestID) { await load() }
    }

    private func load() async {
        let request = requestID
        loadedRequest = request
        phase = .loading
        showSearch = false
        showExisting = false
        guard let settings = container?.lidarrSettings, settings.isConnected else {
            phase = .disconnected
            return
        }
        do {
            let client = await settings.makeClient()
            try Task.checkCancellation()
            guard request == requestID else { return }
            guard let client else {
                phase = .disconnected
                return
            }
            let resolution = try await LidarrArtistResolver.resolve(mbid: artist.mbid, using: client)
            try Task.checkCancellation()
            guard request == requestID else { return }
            phase = .ready(resolution, client)
            if case .search = resolution { showSearch = true }
        } catch {
            guard !Task.isCancelled, request == requestID else { return }
            phase = .failed(LidarrLibraryView.message(for: (error as? LidarrError) ?? .transport(error.localizedDescription)))
        }
    }
}
