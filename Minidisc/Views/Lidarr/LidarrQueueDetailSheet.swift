import SwiftUI

/// The detail of one download in the activity queue, presented when its row is tapped: what Lidarr is
/// doing with it, why it is stuck, and the two things the user can do about it — import the files by
/// hand, or drop it from the queue. Removing asks for its options in place, on a second step, so the
/// user still sees what they are about to remove.
struct LidarrQueueDetailSheet: View {
    let item: LidarrQueueItem
    let client: LidarrClient
    /// Removes the item with the options the user picked. The queue owns the call so its list updates as
    /// soon as this sheet closes.
    let onRemove: (_ removeFromClient: Bool, _ blocklist: Bool, _ searchForReplacement: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .detail
    @State private var showManualImport = false
    @State private var removeFromClient = true
    @State private var blocklist = false
    @State private var searchForReplacement = false

    private enum Step { case detail, remove }

    var body: some View {
        Group {
            switch step {
            case .detail: detailStep
            case .remove: removeStep
            }
        }
        .animation(.snappy, value: step)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showManualImport) {
            if let downloadId = item.downloadId {
                NavigationStack {
                    LidarrManualImportView(
                        downloadId: downloadId,
                        navigationTitle: item.displayTitle,
                        client: client,
                        onImported: { dismiss() }
                    )
                }
            }
        }
    }

    // MARK: - Detail step

    /// The banner already names the state, so the information list only repeats it when there is none.
    private var showsStatusBanner: Bool { item.hasIssue || !item.allMessages.isEmpty }

    private var detailStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MinidiscSpacing.l) {
                header
                if showsStatusBanner { statusBanner }
                actionButtons
                infoSection
            }
            .padding(.horizontal, MinidiscSpacing.l)
            .padding(.top, MinidiscSpacing.xl)
            .padding(.bottom, MinidiscSpacing.l)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            HStack(alignment: .top, spacing: MinidiscSpacing.m) {
                VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                    Text(item.displayTitle)
                        .font(.minidiscDetailTitle)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: MinidiscSpacing.xs) {
                        if let quality = item.qualityName { Text(quality) }
                        if let size = item.totalSize {
                            if item.qualityName != nil { Text("·") }
                            Text(LidarrFormat.size(size))
                        }
                    }
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                Button(role: .close) {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(.primary)
                .accessibilityLabel("Close")
            }

            if item.progress > 0 && item.progress < 1 { progressRow }
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            ProgressView(value: item.progress)
                .tint(item.hasIssue ? Color.orange : Color.minidiscAccent)

            HStack {
                Text(item.progress.formatted(.percent.precision(.fractionLength(1))))
                Spacer(minLength: 0)
                if let remaining = item.timeRemaining {
                    Text("\(remaining) left")
                }
            }
            .font(.minidiscCaption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            Label(
                item.statusLabel,
                systemImage: item.hasIssue ? "exclamationmark.triangle.fill" : "info.circle.fill"
            )
            .font(.minidiscCellTitle)
            .fontWeight(.bold)
            .foregroundStyle(item.hasIssue ? Color.orange : Color.secondary)

            ForEach(item.allMessages, id: \.self) { message in
                Text(message)
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MinidiscSpacing.m)
        .background(
            (item.hasIssue ? Color.orange : Color.secondary).opacity(0.15),
            in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Button {
                step = .remove
            } label: {
                Label("Remove", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MinidiscSpacing.s)
            }
            .tint(.red)

            if item.canManuallyImport {
                Button {
                    showManualImport = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, MinidiscSpacing.s)
                }
                .tint(.minidiscAccent)
            }
        }
        .buttonStyle(.bordered)
    }

    private var infoRows: [(label: LocalizedStringKey, value: String)] {
        var rows: [(label: LocalizedStringKey, value: String)] = []
        if !showsStatusBanner { rows.append(("Status", item.statusLabel)) }
        if let artist = item.artist?.artistName { rows.append(("Artist", artist)) }
        if let album = item.album?.title { rows.append(("Album", album)) }
        if let quality = item.qualityName { rows.append(("Quality", quality)) }
        if let size = item.totalSize { rows.append(("Size", LidarrFormat.size(size))) }
        if let remaining = item.timeRemaining, item.progress < 1 { rows.append(("Time Left", remaining)) }
        if let network = item.protocol { rows.append(("Protocol", network.capitalized)) }
        if let indexer = item.indexer { rows.append(("Indexer", indexer)) }
        if let downloadClient = item.downloadClient { rows.append(("Client", downloadClient)) }
        if let added = item.addedDate {
            rows.append(("Added", added.formatted(date: .abbreviated, time: .shortened)))
        }
        return rows
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text("Information")
                .font(.minidiscShelfTitle)

            VStack(spacing: 0) {
                ForEach(Array(infoRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    LabeledContent(row.label) {
                        Text(row.value).multilineTextAlignment(.trailing)
                    }
                    .font(.minidiscBody)
                    .padding(.vertical, MinidiscSpacing.s)
                }
            }
        }
    }

    // MARK: - Remove step

    private var removeStep: some View {
        VStack(spacing: 0) {
            removeBar
                .padding(.horizontal, MinidiscSpacing.l)
                .padding(.top, MinidiscSpacing.l)

            Form {
                Section {
                    Toggle("Remove from Client", isOn: $removeFromClient)
                } footer: {
                    Text("Whether to ignore the download, or remove it and its files from the download client.")
                }

                Section {
                    Toggle("Blocklist Release", isOn: $blocklist)

                    // Only blocklisting makes replacing the release possible.
                    if blocklist {
                        Toggle("Search for Replacement", isOn: $searchForReplacement)
                    }
                } footer: {
                    Text("Blocks this release from being redownloaded via Automatic Search or RSS.")
                }
            }
            .formStyle(.grouped)
            // Switches keep the system colour rather than the app's accent.
            .tint(nil)
            .contentMargins(.top, MinidiscSpacing.m, for: .scrollContent)
        }
    }

    private var removeBar: some View {
        HStack {
            Button {
                step = .detail
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .tint(.primary)
            .accessibilityLabel("Back")

            Spacer(minLength: 0)

            Button(role: .destructive) {
                onRemove(removeFromClient, blocklist, blocklist && searchForReplacement)
                dismiss()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.red, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Download")
        }
    }
}
