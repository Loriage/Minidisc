// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

private enum OnboardingStep {
    case welcome, complete
}

struct OnboardingView: View {
    @Environment(\.appContainer) private var container
    @State private var step: OnboardingStep = .welcome
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeView(onServerConnected: { step = .complete })
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
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
            // Existing users upgrading: server already set, skip all onboarding steps.
            if container?.serverState.activeServer != nil {
                onboardingComplete = true
            }
        }
    }
}

#Preview {
    OnboardingView()
}
