import SwiftUI

private enum OnboardingStep {
    case welcome, localFiles, complete
}

struct OnboardingView: View {
    @Environment(\.appContainer) private var container
    @State private var step: OnboardingStep = .welcome
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("minidisc.localMusicEnabled") private var localMusicEnabled = false

    var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeView(onServerConnected: { step = .complete }, onLocalFiles: { step = .localFiles })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            case .localFiles:
                NavigationStack {
                    LocalMusicFoldersView(isOnboarding: true)
                        .safeAreaInset(edge: .bottom) {
                            Button {
                                onboardingComplete = true
                                localMusicEnabled = true
                            } label: {
                                Text("Open My Library", tableName: "LocalMusic")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(MinidiscColors.accent)
                            .disabled(container?.localMusic.isRefreshing == true)
                            .accessibilityIdentifier("onboarding.openLocalLibrary")
                            .padding()
                            .background(MinidiscColors.backgroundPrimary)
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Back", systemImage: "chevron.left") { step = .welcome }
                            }
                        }
                }
            case .complete:
                OnboardingCompleteView(onComplete: { onboardingComplete = true })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: step)
        .task {
            if container?.serverState.activeServer != nil {
                onboardingComplete = true
            }
        }
    }
}

#Preview {
    OnboardingView()
}
