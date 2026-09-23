import SwiftUI

struct OfflineFavoritesSettingsSection: View {
    let settings: CacheSettings
    let sync: OfflineFavoritesSync

    var body: some View {
        Section {
            Toggle("Keep Favorites Offline", isOn: Binding(
                get: { settings.keepFavoritesOffline },
                set: { settings.keepFavoritesOffline = $0 }
            ))
            .tint(Color(.systemGreen))
            .accessibilityIdentifier("offline-favorites-toggle")

            LabeledContent("Disk usage") {
                usageText
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityIdentifier("offline-favorites-usage")

            if settings.keepFavoritesOffline {
                if sync.isSyncing {
                    HStack {
                        ProgressView()
                        if sync.total == 0 { Text("Preparing…").foregroundStyle(.secondary) }
                        else {
                            Text("\(sync.completed) of \(sync.total) tracks ready")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if sync.waitingForConnection {
                    Label("Waiting for a connection", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                } else if sync.waitingForWiFi {
                    Label("Waiting for an unrestricted connection", systemImage: "wifi")
                        .foregroundStyle(.secondary)
                }

                if let error = sync.error {
                    Text(error.displayMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Sync Favorites Now") { sync.revision += 1 }
                    .disabled(sync.isSyncing || sync.waitingForConnection || sync.waitingForWiFi)
                    .accessibilityIdentifier("offline-favorites-sync")
            }
        } header: {
            Text("Offline favorites")
        } footer: {
            Text("Favorite tracks and albums are saved automatically, outside Downloads and the stream cache limit. Turning this off removes only these automatic copies. Uses the stream cache format and cellular data settings.")
        }
        .task { await sync.refreshUsage() }
    }

    private var usageText: Text {
        let size = ByteCountFormatter.string(fromByteCount: sync.usage.bytes, countStyle: .file)
        if sync.usage.count == 1 { return Text("1 track · \(size)") }
        return Text("\(sync.usage.count) tracks · \(size)")
    }
}
