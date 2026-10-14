import SwiftUI
import SwiftSonic

/// Every album in a genre or from a record label, opened from the chips under an album title.
struct AlbumCollectionView: View {
    let kind: AlbumCollectionKind

    @Environment(\.appContainer) private var container
    @State private var viewModel: AlbumCollectionViewModel?

    /// `viewModel` is for Previews: a supplied model is loaded instead of one built from the container.
    init(kind: AlbumCollectionKind, viewModel: AlbumCollectionViewModel? = nil) {
        self.kind = kind
        _viewModel = State(initialValue: viewModel)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: MinidiscSpacing.l)
    ]

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                LoadingStateView()
            }
        }
        .navigationTitle(Text(verbatim: kind.name))
        .navigationBarTitleDisplayModeInline()
        .task {
            if let viewModel {
                if viewModel.state == .loading { await viewModel.load() }
                return
            }
            guard let library = container?.libraryService else { return }
            let model = AlbumCollectionViewModel(kind: kind, library: library)
            viewModel = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ viewModel: AlbumCollectionViewModel) -> some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case .waitingForIndex:
            EmptyStateView(
                systemImage: "hourglass",
                title: "Still Indexing Your Library",
                subtitle: "Label pages appear once Minidisc has indexed every album. Try again shortly."
            )
        case .failed(let error):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Albums",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await viewModel.load() } }
            )
        case .loaded where viewModel.albums.isEmpty:
            EmptyStateView(
                systemImage: "square.stack",
                title: "No Albums",
                subtitle: "Nothing in your library matches."
            )
        case .loaded:
            let albums = container?.visibleAlbums(viewModel.albums) ?? viewModel.albums
            ScrollView {
                VStack(alignment: .leading, spacing: MinidiscSpacing.xxl) {
                    header(viewModel, albumCount: albums.count)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: MinidiscSpacing.l) {
                        ForEach(albums) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                AlbumGridCell(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(MinidiscSpacing.l)
            }
            .refreshable { await viewModel.load() }
            .miniPlayerBottomMargin()
            .minidiscContentWidth()
        }
    }

    private func header(_ viewModel: AlbumCollectionViewModel, albumCount: Int) -> some View {
        HStack(spacing: MinidiscSpacing.m) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(Color.minidiscAccent)
                .frame(width: MinidiscControlSize.regular, height: MinidiscControlSize.regular)
                .background(Circle().fill(Color.minidiscAccent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: kind.name)
                    .font(.minidiscSectionTitle)
                    .lineLimit(2)
                Text("\(albumCount) albums")
                    .font(.minidiscMetadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: MinidiscSpacing.s)
            Button("Play All", systemImage: "play.fill") {
                Task { await play(viewModel, shuffled: false) }
            }
            .buttonStyle(.minidiscCircle(isProminent: true))
            Button("Shuffle", systemImage: "shuffle") {
                Task { await play(viewModel, shuffled: true) }
            }
            .buttonStyle(.minidiscCircle())
        }
        .disabled(viewModel.isPlayLoading || albumCount == 0)
        .padding(MinidiscSpacing.l)
        .background(
            RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous)
                .fill(.primary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
    }

    /// Plays every album in the collection, in the page's order, or shuffled across all their tracks.
    private func play(_ viewModel: AlbumCollectionViewModel, shuffled: Bool) async {
        guard let container, !viewModel.isPlayLoading else { return }
        viewModel.isPlayLoading = true
        defer { viewModel.isPlayLoading = false }
        HapticFeedback.medium.trigger()
        let albums = container.visibleAlbums(viewModel.albums)
        var tracks = await AlbumTrackLoader.tracks(for: albums, library: container.libraryService)
        guard !Task.isCancelled else { return }
        guard !tracks.isEmpty else {
            container.toastService.showError(String(localized: "Unable to load these albums. Please try again."))
            return
        }
        if shuffled { tracks.shuffle() }
        await container.toastService.perform { try await container.playerService.play(tracks: tracks, startIndex: 0) }
    }
}

#if DEBUG
#Preview("Genre") {
    MinidiscPreview(container: .preview()) {
        NavigationStack {
            AlbumCollectionView(
                kind: .genre("Indie Pop"),
                viewModel: AlbumCollectionViewModel(kind: .genre("Indie Pop"), library: PreviewLibraryService())
            )
        }
    }
}
#endif
