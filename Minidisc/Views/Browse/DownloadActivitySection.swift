import SwiftUI

struct DownloadActivitySection: View {
    let serverID: UUID
    @Environment(\.appContainer) private var container

    var body: some View {
        if let container {
            let transfers = container.downloadActivity.transfers.filter { $0.serverId == serverID }
            if !transfers.isEmpty {
                Section("Transfers") {
                    ForEach(transfers, id: \.songId) { transfer in
                        DownloadActivityRow(transfer: transfer)
                    }
                }
            }
        }
    }
}

private struct DownloadActivityRow: View {
    let transfer: DownloadProgress
    @Environment(\.appContainer) private var container

    private var status: LocalizedStringResource {
        switch transfer.status {
        case .queued: "Queued"
        case .waiting: "Waiting for connection…"
        case .processing: "Finishing download…"
        case .downloading: "Downloading…"
        case .failed: "Download failed"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: MinidiscSpacing.m) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                Text(transfer.title ?? String(localized: "Song"))
                    .font(.body).lineLimit(2)
                if let error = transfer.error {
                    Text(error.displayMessage).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if transfer.totalBytes != nil {
                        ProgressView(value: transfer.progress)
                            .accessibilityLabel("Download progress")
                        Text(transfer.receivedBytes, format: .byteCount(style: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if transfer.status == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await container?.toastService.perform {
                        try await container?.downloadService.retryDownload(songId: transfer.songId, serverId: transfer.serverId)
                    } }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
            }
            Button("Cancel Download", systemImage: "xmark") {
                Task { await container?.toastService.perform {
                    try await container?.downloadService.cancelDownload(songId: transfer.songId, serverId: transfer.serverId)
                } }
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, MinidiscSpacing.xs)
    }
}
