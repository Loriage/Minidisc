// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct OnboardingCompleteView: View {
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var transitioning = false

    var body: some View {
        ZStack {
            MinidiscColors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(MinidiscColors.accent)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(duration: 0.6, bounce: 0.4), value: appeared)

                Spacer().frame(height: MinidiscSpacing.xxxxl)

                VStack(spacing: MinidiscSpacing.m) {
                    Text("You're all set.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(MinidiscColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.2), value: appeared)

                    Text("Your library is waiting.\nTime to press play.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(MinidiscColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.3), value: appeared)

                    Text("You can adjust everything anytime in Settings.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(MinidiscColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.4), value: appeared)
                }
                .padding(.horizontal, MinidiscSpacing.xxxl)

                Spacer()

                Button {
                    startTransition()
                } label: {
                    Text("Start Listening")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(MinidiscColors.accent)
                .padding(.horizontal, MinidiscSpacing.xxxl)
                .padding(.bottom, MinidiscSpacing.xxxl)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 30)
                .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.5), value: appeared)
            }

            // Fade-to-black overlay — fully opaque before handoff to main app
            Color.black
                .ignoresSafeArea()
                .opacity(transitioning ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: transitioning)
                .allowsHitTesting(false)
        }
        .onAppear { appeared = true }
    }

    private func startTransition() {
        transitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onComplete()
        }
    }
}
