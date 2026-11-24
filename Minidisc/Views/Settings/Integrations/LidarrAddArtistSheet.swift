import SwiftUI

struct LidarrAddArtistSheet: View {
    let artist: LidarrArtistLookup
    let client: LidarrClient
    let onAdded: () -> Void

    var body: some View {
        NavigationStack {
            LidarrAddArtistForm(artist: artist, client: client, onAdded: onAdded)
        }
    }
}

struct LidarrAddArtistForm: View {
    let artist: LidarrArtistLookup
    let client: LidarrClient
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rootFolders: [LidarrRootFolder] = []
    @State private var qualityProfiles: [LidarrProfile] = []
    @State private var metadataProfiles: [LidarrProfile] = []
    @State private var tags: [LidarrTag] = []
    @State private var selectedTags: Set<Int> = []

    @State private var selectedRootFolder: Int?
    @State private var selectedQuality: Int?
    @State private var selectedMetadata: Int?
    @State private var monitor: LidarrMonitorOption = .all
    @State private var searchOnAdd = true

    @State private var isLoading = true
    @State private var didLoadOptions = false
    @State private var optionsError: String?
    @State private var loadAttempt = 0
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var canAdd: Bool {
        !isLoading && optionsError == nil && selectedRootFolder != nil
            && selectedQuality != nil && selectedMetadata != nil && !isAdding
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: MinidiscSpacing.m) {
                        poster
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.artistName).font(.minidiscCellTitle).lineLimit(2)
                            if let disambiguation = artist.disambiguation, !disambiguation.isEmpty {
                                Text(disambiguation).font(.minidiscCaption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }

                if isLoading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if let optionsError {
                    Section {
                        Label("Couldn't Load Artist Options", systemImage: "exclamationmark.triangle")
                        Text(optionsError)
                            .font(.minidiscCaption)
                            .foregroundStyle(.secondary)
                        Button("Retry") { loadAttempt += 1 }
                            .accessibilityIdentifier("lidarr.options.retry")
                    }
                } else {
                    Section {
                        Picker("Root Folder", selection: $selectedRootFolder) {
                            ForEach(rootFolders) { folder in
                                Text(folder.path).tag(Int?.some(folder.id))
                            }
                        }
                        Picker("Quality Profile", selection: $selectedQuality) {
                            ForEach(qualityProfiles) { profile in
                                Text(profile.name).tag(Int?.some(profile.id))
                            }
                        }
                        Picker("Metadata Profile", selection: $selectedMetadata) {
                            ForEach(metadataProfiles) { profile in
                                Text(profile.name).tag(Int?.some(profile.id))
                            }
                        }
                        LidarrTagsField(tags: tags, selection: $selectedTags)
                            .disabled(isAdding)
                        Picker("Monitor", selection: $monitor) {
                            ForEach(LidarrMonitorOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        Toggle("Search for missing albums", isOn: $searchOnAdd)
                            .tint(Color(.systemGreen))
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.minidiscCaption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add Artist")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await add() }
                    } label: {
                        if isAdding { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
                    .accessibilityIdentifier("lidarr.confirm-add")
                }
            }
        }
        .task(id: loadAttempt) { await loadOptions() }
    }

    @ViewBuilder
    private var poster: some View {
        AsyncImage(url: artist.posterURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                .fill(Color.secondary.opacity(0.15))
                .overlay { Image(systemName: "music.mic").foregroundStyle(.secondary) }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
    }

    private func loadOptions() async {
        guard !didLoadOptions else { return }
        isLoading = true
        optionsError = nil
        do {
            async let folders = client.rootFolders()
            async let quality = client.qualityProfiles()
            async let metadata = client.metadataProfiles()
            async let availableTags = client.tags()
            let (f, q, m, t) = try await (folders, quality, metadata, availableTags)
            try Task.checkCancellation()
            rootFolders = f
            qualityProfiles = q
            metadataProfiles = m
            tags = t.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            selectedRootFolder = f.first?.id
            selectedQuality = q.first?.id
            selectedMetadata = m.first?.id
            didLoadOptions = true
        } catch {
            guard !Task.isCancelled else { return }
            optionsError = friendlyMessage(error)
        }
        isLoading = false
    }

    private func add() async {
        guard canAdd, let rootId = selectedRootFolder,
              let root = rootFolders.first(where: { $0.id == rootId }),
              let qualityId = selectedQuality,
              let metadataId = selectedMetadata else { return }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }

        let request = LidarrAddArtistRequest(
            artist: artist,
            qualityProfileId: qualityId,
            metadataProfileId: metadataId,
            rootFolderPath: root.path,
            monitor: monitor,
            searchForMissingAlbums: searchOnAdd,
            tags: selectedTags
        )
        do {
            try await client.addArtist(request)
            NotificationCenter.default.post(name: .lidarrLibraryDidChange, object: nil)
            onAdded()
            dismiss()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private func friendlyMessage(_ error: Error) -> String {
        guard let lidarr = error as? LidarrError else { return error.localizedDescription }
        switch lidarr {
        case .unauthorized: return String(localized: "The API key was rejected.")
        case .htmlResponse: return String(localized: "A reverse proxy is blocking the request.")
        case .offline: return UserFacingError.noNetwork.displayMessage
        case .cancelled: return String(localized: "The request was cancelled.")
        case .badURL: return String(localized: "The Lidarr address is not valid.")
        case .transport(let detail), .decoding(let detail): return detail
        }
    }
}
