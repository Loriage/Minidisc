import SwiftUI

struct RootView: View {
    @Environment(\.appContainer) private var container
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    @AppStorage("minidisc.localMusicEnabled") private var localMusicEnabled = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .task(id: scenePhase) {
                guard scenePhase == .active, let library = container?.localMusic else { return }
                while !Task.isCancelled {
                    await library.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let serverState = container?.serverState {
            if serverState.isLoadingPersistedState {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if (serverState.activeServer != nil && onboardingComplete) || localMusicEnabled {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
    }
}
