import SwiftUI
import SwiftSonic

/// A track credits several artists: choose which one to open.
struct ArtistPickerRequest: Identifiable {
    let id = UUID()
    let trackTitle: String
    let credits: [ArtistCredit]
}

/// Lists a track's credited artists with their photos, split into artists with albums in the library
/// (tagged with how many) and artists without. Every row opens the artist page.
struct ArtistPickerSheet: View {
    let request: ArtistPickerRequest
    /// Receives the chosen credit, with the library ID filled in when it was resolved by name.
    let onSelect: (ArtistCredit) -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ArtistPickerViewModel?

    private static let avatarSize: CGFloat = 48

    var body: some View {
        NavigationStack {
            List {
                if let viewModel {
                    if viewModel.isResolving {
                        Section {
                            ForEach(viewModel.entries) { row($0, isResolving: true) }
                        }
                    } else {
                        if !viewModel.inLibrary.isEmpty {
                            Section("In Your Library") {
                                ForEach(viewModel.inLibrary) { row($0, isResolving: false) }
                            }
                        }
                        if !viewModel.notInLibrary.isEmpty {
                            Section("Not in Your Library") {
                                ForEach(viewModel.notInLibrary) { row($0, isResolving: false) }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("artist.picker")
            .navigationTitle("Select Artist")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .animation(.smooth(duration: 0.25), value: viewModel?.isResolving)
        }
        .presentationDetents([.medium, .large])
        .task {
            guard viewModel == nil, let library = container?.libraryService else { return }
            let model = ArtistPickerViewModel(credits: request.credits, library: library)
            viewModel = model
            await model.resolve()
        }
    }

    private func row(_ entry: ArtistPickerViewModel.Entry, isResolving: Bool) -> some View {
        Button {
            dismiss()
            onSelect(ArtistCredit(id: entry.artist?.id ?? entry.credit.id, name: entry.artist?.name ?? entry.credit.name))
        } label: {
            HStack(spacing: MinidiscSpacing.m) {
                avatar(for: entry)
                Text(verbatim: entry.credit.name)
                    .font(.minidiscBody)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: MinidiscSpacing.s)
                if isResolving && entry.albumCount == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if let count = entry.albumCount, count > 0 {
                    MetadataChip(text: String(localized: "\(count) albums"))
                }
                Image(systemName: "chevron.right")
                    .font(.minidiscCaption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("artist.picker.row.\(entry.id)")
    }

    @ViewBuilder
    private func avatar(for entry: ArtistPickerViewModel.Entry) -> some View {
        Group {
            if let coverArtID = entry.coverArtID, !coverArtID.isEmpty {
                CoverArtView(id: coverArtID, size: Int(Self.avatarSize * 3), placeholderSystemImage: "music.mic")
            } else {
                ArtistPlaceholderView(name: entry.credit.name, size: Self.avatarSize)
            }
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

#Preview {
    MinidiscPreview(container: .preview()) {
        ArtistPickerSheet(
            request: ArtistPickerRequest(
                trackTitle: "Salt in the Static",
                credits: [
                    ArtistCredit(id: PreviewFixtures.noraVale.id, name: PreviewFixtures.noraVale.name),
                    ArtistCredit(id: PreviewFixtures.hanaOkafor.id, name: PreviewFixtures.hanaOkafor.name),
                    ArtistCredit(id: nil, name: "Ajay Prasanna")
                ]
            ),
            onSelect: { _ in }
        )
    }
}
