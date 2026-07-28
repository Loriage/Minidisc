import SwiftUI

/// A pushed route to the Lidarr activity queue.
struct LidarrQueueRoute: Hashable {}

/// The Lidarr activity queue: the downloads Lidarr is tracking, with progress and, on tap, what to do
/// with one — import it by hand, or drop it from the queue.
struct LidarrQueueView: View {
    let client: LidarrClient

    @Environment(\.appContainer) private var container

    @State private var items: [LidarrQueueItem] = []
    @State private var selectedItem: LidarrQueueItem?
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
        .sheet(item: $selectedItem) { item in
            LidarrQueueDetailSheet(item: item, client: client) { removeFromClient, blocklist, search in
                Task {
                    await remove(
                        item,
                        removeFromClient: removeFromClient,
                        blocklist: blocklist,
                        searchForReplacement: search
                    )
                }
            }
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
                Button {
                    selectedItem = item
                } label: {
                    LidarrQueueRow(item: item)
                }
                .buttonStyle(.plain)
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

    /// Drops one download. The swipe action uses Lidarr's own defaults; the detail sheet passes what the
    /// user picked there.
    private func remove(
        _ item: LidarrQueueItem,
        removeFromClient: Bool = true,
        blocklist: Bool = false,
        searchForReplacement: Bool = false
    ) async {
        do {
            try await client.removeQueueItem(
                id: item.id,
                removeFromClient: removeFromClient,
                blocklist: blocklist,
                searchForReplacement: searchForReplacement
            )
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

            Image(systemName: "chevron.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, MinidiscSpacing.xs)
        .contentShape(Rectangle())
    }
}
