import SwiftUI

struct RootView: View {
    @Environment(\.appContainer) private var container
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        if let serverState = container?.serverState {
            if serverState.isLoadingPersistedState {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if serverState.activeServer != nil && onboardingComplete {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
    }
}
