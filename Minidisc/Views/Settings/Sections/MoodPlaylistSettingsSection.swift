import SwiftUI

struct MoodPlaylistSettingsSection: View {
    @Environment(\.appContainer) private var container
    @AppStorage(MoodPreferences.automaticGenerationKey) private var automaticGeneration = true
    @State private var request: RegenerationRequest?
    @State private var outcome: MoodSyncOutcome?

    private struct RegenerationRequest: Equatable {
        let id = UUID()
        let serverId: String
    }

    private var serverId: String? { container?.serverState.activeServer?.id.uuidString }

    var body: some View {
        Section {
            Toggle("Automatic generation", isOn: $automaticGeneration)
                .accessibilityIdentifier("mood-automatic-generation")
            Button {
                guard let serverId else { return }
                outcome = nil
                request = RegenerationRequest(serverId: serverId)
            } label: {
                HStack {
                    Text("Regenerate playlists")
                    if request != nil {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("mood-regenerate-playlists")
            .disabled(request != nil || serverId == nil)
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
            let result = await service.rebuildNow(serverId: request.serverId)
            guard !Task.isCancelled, serverId == request.serverId else { return }
            outcome = result
            self.request = nil
        }
        .onChange(of: serverId) {
            request = nil
            outcome = nil
        }
        .onDisappear { request = nil }
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
