import SwiftUI

struct OfflineBrowsingEmptyView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if container?.offlineLibrary.isLoading == true {
            LoadingStateView()
        } else {
            ContentUnavailableView {
                Label("You're Offline", systemImage: "wifi.slash")
            } description: {
                Text("No music is available offline. Download music or save favorites before going offline.")
            }
        }
    }
}
