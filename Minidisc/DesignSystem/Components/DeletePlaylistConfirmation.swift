import SwiftUI

extension View {
    /// onConfirm receives whether downloaded files should also be removed.
    func deletePlaylistConfirmation(
        playlistName: String,
        isPresented: Binding<Bool>,
        hasDownloads: Bool,
        onConfirm: @escaping (_ purgeDownloads: Bool) -> Void
    ) -> some View {
        confirmationDialog(
            "Delete \"\(playlistName)\"?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            if hasDownloads {
                Button("Delete Playlist Only", role: .destructive) { onConfirm(false) }
                Button("Delete Playlist & Downloads", role: .destructive) { onConfirm(true) }
            } else {
                Button("Delete", role: .destructive) { onConfirm(false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hasDownloads
                ? "This removes the playlist from your server. You can keep the files downloaded on this device, or remove them too. This cannot be undone."
                : "This permanently deletes the playlist from your server. This action cannot be undone.")
        }
    }
}
