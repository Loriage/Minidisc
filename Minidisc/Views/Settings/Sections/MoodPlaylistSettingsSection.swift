import SwiftUI

struct MoodPlaylistSettingsSection: View {
    @Environment(\.appContainer) private var container
    @AppStorage(MoodPreferences.automaticGenerationKey) private var automaticGeneration = true
    @State private var request: PlaylistRequest?
    @State private var outcome: MoodSyncOutcome?
    @State private var deletionOutcome: MoodDeletionOutcome?
    @State private var showDeleteConfirmation = false

    private enum Action { case regenerate, delete }

    private struct PlaylistRequest: Equatable {
        let id = UUID()
        let serverId: String
        let action: Action
    }

    private var serverId: String? { container?.serverState.activeServer?.id.uuidString }

    var body: some View {
        Section {
            Toggle("Automatic generation", isOn: $automaticGeneration)
                .accessibilityIdentifier("mood-automatic-generation")
                .disabled(request?.action == .delete)
            Button {
                start(.regenerate)
            } label: {
                HStack {
                    Text("Regenerate playlists")
                    if request?.action == .regenerate {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("mood-regenerate-playlists")
            .disabled(request != nil || serverId == nil)
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Text("Delete mood playlists")
                    if request?.action == .delete {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("mood-delete-playlists")
            .disabled(request != nil || serverId == nil)
            if let deletionOutcome {
                MoodDeletionResult(outcome: deletionOutcome)
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
            }
            if let outcome {
                MoodRegenerationResult(outcome: outcome)
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
            }
            if serverId == nil {
                Text("No server configured.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Mood playlists")
        } footer: {
            Text("Automatically create and refresh mood playlists each week. Disabling this keeps existing playlists. You can regenerate them manually at any time.")
        }
        .task(id: request) {
            guard let request, let service = container?.moodPlaylistService else { return }
            switch request.action {
            case .regenerate:
                let result = await service.rebuildNow(serverId: request.serverId)
                guard !Task.isCancelled, serverId == request.serverId else { return }
                outcome = result
            case .delete:
                let result = await service.deletePlaylists(serverId: request.serverId)
                guard !Task.isCancelled, serverId == request.serverId else { return }
                deletionOutcome = result
            }
            self.request = nil
        }
        .onChange(of: serverId) {
            request = nil
            outcome = nil
            deletionOutcome = nil
            showDeleteConfirmation = false
        }
        .onDisappear { request = nil }
        .alert("Delete mood playlists?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { start(.delete) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your Minidisc mood playlists from the current server and disables automatic generation. Other playlists and downloaded music are kept.")
        }
    }

    private func start(_ action: Action) {
        guard let serverId else { return }
        outcome = nil
        deletionOutcome = nil
        request = PlaylistRequest(serverId: serverId, action: action)
    }

}

private struct MoodRegenerationResult: View {
    let outcome: MoodSyncOutcome

    var body: some View {
        switch outcome {
        case .finished(_, let refreshed, let kept) where !refreshed.isEmpty && kept.isEmpty:
            Text("Mood playlists regenerated.")
        case .finished(_, let refreshed, _) where !refreshed.isEmpty:
            Text("Some mood playlists could not be regenerated. Try again later.")
        case .inProgress:
            Text("Mood playlists are already being updated. Try again when the update is complete.")
        case .cancelled:
            Text("Regeneration cancelled.")
        default:
            Text("Could not regenerate mood playlists. Check your connection and music sources, then try again.")
        }
    }
}

private struct MoodDeletionResult: View {
    let outcome: MoodDeletionOutcome

    var body: some View {
        switch outcome {
        case .finished(_, let failed) where failed == 0:
            Text("Mood playlists deleted. Automatic generation is off.")
        case .finished(let deleted, _) where deleted > 0:
            Text("Some mood playlists could not be deleted. Automatic generation is off. Try again later.")
        case .inProgress:
            Text("Mood playlists are already being updated. Try again when the update is complete.")
        case .cancelled:
            Text("Deletion cancelled.")
        default:
            Text("Could not delete mood playlists. Check your connection and permissions, then try again.")
        }
    }
}
