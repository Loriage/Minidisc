import SwiftUI

/// A pushed route to the Lidarr activity queue.
struct LidarrQueueRoute: Hashable {}

/// A pushed route to the manual import of one stuck download.
struct LidarrManualImportRoute: Hashable {
    let downloadId: String
    let title: String
}

/// The Lidarr activity queue: the downloads Lidarr is tracking, with progress and a way to manually
/// import the ones it could not sort out on its own.
struct LidarrQueueView: View {
    let client: LidarrClient

    @Environment(\.appContainer) private var container

    @State private var items: [LidarrQueueItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                pullableState {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't Load Queue",
                        subtitle: LocalizedStringKey(errorMessage),
                        action: .init(label: "Retry") { Task { await load() } }
                    )
                }
            } else if items.isEmpty {
                pullableState {
                    EmptyStateView(systemImage: "checkmark.circle", title: "Queue Empty", subtitle: "No downloads are in progress.")
                }
            } else {
                queueList
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayModeInline()
        .navigationDestination(for: LidarrManualImportRoute.self) { route in
            LidarrManualImportView(downloadId: route.downloadId, navigationTitle: route.title, client: client)
        }
        .task { await load() }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .lidarrQueueDidChange)) { _ in
            Task { await load() }
        }
    }

    /// Wraps a non-scrolling placeholder in a full-height, always-bouncing ScrollView so the outer
    /// `.refreshable` still gets a pull gesture when the queue is empty or errored — otherwise the user
    /// can't pull to check whether Lidarr has pushed new downloads.
    private func pullableState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.always)
    }

    private var queueList: some View {
        List {
            ForEach(items) { item in
                Group {
                    if item.needsManualImport, let downloadId = item.downloadId {
                        NavigationLink(value: LidarrManualImportRoute(downloadId: downloadId, title: item.displayTitle)) {
                            LidarrQueueRow(item: item)
                        }
                    } else {
                        LidarrQueueRow(item: item)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await remove(item) }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        errorMessage = nil
        do {
            items = try await client.queue()
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = LidarrLibraryView.message(for: (error as? LidarrError) ?? .transport(error.localizedDescription))
            }
        }
        isLoading = false
    }

    private func remove(_ item: LidarrQueueItem) async {
        do {
            try await client.removeQueueItem(id: item.id, removeFromClient: true, blocklist: false)
            items.removeAll { $0.id == item.id }
            container?.toastService.showConfirmation(String(localized: "Removed from queue"))
        } catch {
            container?.toastService.showError(String(localized: "Couldn't remove the download."))
        }
    }
}

// MARK: - Row

private struct LidarrQueueRow: View {
    let item: LidarrQueueItem

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.minidiscCellTitle)
                    .lineLimit(2)

                HStack(spacing: MinidiscSpacing.xs) {
                    Text(item.statusLabel)
                        .foregroundStyle(item.hasIssue ? .orange : .secondary)
                    if let quality = item.qualityName {
                        Text("·")
                        Text(quality)
                    }
                }
                .font(.minidiscCaption)

                if item.hasIssue, let detail = item.issueDetail {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.minidiscCaption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                if item.progress > 0 && item.progress < 1 {
                    ProgressView(value: item.progress)
                        .tint(item.hasIssue ? .orange : .minidiscAccent)
                }
            }
            Spacer(minLength: 0)

            if item.needsManualImport {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, MinidiscSpacing.xs)
    }
}
