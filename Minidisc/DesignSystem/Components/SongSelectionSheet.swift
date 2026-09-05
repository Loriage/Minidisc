import SwiftUI

struct SongSelectionRequest: Identifiable {
    let id = UUID()
    let songs: [DisplayableSong]
}

/// A fixed collection snapshot keeps a refresh from changing what a multi-selection means.
/// Filtering never clears the selection; commit follows the collection's displayed order.
struct SongSelectionSheet: View {
    let request: SongSelectionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var addition: PlaylistAdditionRequest?

    private var songs: [DisplayableSong] {
        var seen: Set<String> = []
        return request.songs.filter { seen.insert($0.id).inserted }
    }

    private var visibleSongs: [DisplayableSong] {
        let query = LibrarySearchRanking.normalized(query)
        return songs.filter {
            query.isEmpty || LibrarySearchRanking.normalized("\($0.title) \($0.artist ?? "")").contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        let visible = Set(visibleSongs.map(\.id))
                        if selectedIDs.isSuperset(of: visible) { selectedIDs.subtract(visible) }
                        else { selectedIDs.formUnion(visible) }
                    } label: {
                        Text(selectedIDs.isSuperset(of: visibleSongs.map(\.id))
                             ? LocalizedStringResource("Deselect All") : LocalizedStringResource("Select All"))
                    }
                    .disabled(visibleSongs.isEmpty)
                    .accessibilityIdentifier("songs.selection.all")
                } footer: { Text("\(selectedIDs.count) songs selected") }
                ForEach(visibleSongs) { song in
                    Button {
                        if !selectedIDs.insert(song.id).inserted { selectedIDs.remove(song.id) }
                        HapticFeedback.selection.trigger()
                    } label: {
                        SongSelectionRow(song: song, selected: selectedIDs.contains(song.id))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("songs.selection.\(song.id)")
                    .accessibilityAddTraits(selectedIDs.contains(song.id) ? .isSelected : [])
                }
            }
            .minidiscSheetListStyle()
            .searchable(text: $query, prompt: "Find a song")
            .navigationTitle("Select Songs")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Playlist", systemImage: "music.note.list") {
                        addition = PlaylistAdditionRequest(songs: songs.filter { selectedIDs.contains($0.id) })
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("songs.selection.add")
                }
            }
        }
        .sheet(item: $addition) { request in
            AddToPlaylistSheet(request: request, onAdded: { dismiss() })
        }
    }
}

private struct SongSelectionRow: View {
    let song: DisplayableSong
    let selected: Bool

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.minidiscAccent : .secondary)
                .accessibilityHidden(true)
            CoverArtView(id: song.coverArtId ?? song.id, size: 88)
                .frame(width: 44, height: 44)
                .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.xs)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.minidiscCellTitle).lineLimit(2)
                if let artist = song.artist {
                    Text(artist).font(.minidiscCellSubtitle).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MinidiscSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
