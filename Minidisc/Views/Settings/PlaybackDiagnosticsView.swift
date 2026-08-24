import SwiftUI

struct PlaybackDiagnosticsView: View {
    @Environment(\.appContainer) private var container
    @State private var report = ""

    var body: some View {
        Form {
            Section {
                ShareLink(item: report) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
                .disabled(report.isEmpty)

                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            } footer: {
                Text("The report excludes song metadata, complete server URLs, credentials, HTTP headers, and audio device names.")
            }

            if !report.isEmpty {
                Section("Report Preview") {
                    Text(report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Playback Diagnostics")
        .task { refresh() }
    }

    private func refresh() {
        guard let container else { return }
        report = container.makePlaybackDiagnosticsReport()
    }
}
