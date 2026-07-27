import SwiftUI

/// Reusable layout container for optional onboarding steps.
/// Renders a branded header (icon + title + subtitle + progress dots),
/// the step's settings content in a scrollable middle area, and
/// Skip / Continue buttons pinned at the bottom via safeAreaInset.
struct OnboardingStepView<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let stepIndex: Int
    let totalSteps: Int
    let onSkip: () -> Void
    let onContinue: () -> Void
    @ViewBuilder let content: () -> Content

    private var continueLabel: String {
        stepIndex == totalSteps - 1 ? "Done" : "Continue"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .background(MinidiscColors.backgroundPrimary)
            content()
                .safeAreaInset(edge: .bottom) {
                    bottomActions
                }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: MinidiscSpacing.m) {
            ZStack {
                Circle()
                    .fill(MinidiscColors.accentBackground)
                    .frame(width: 60, height: 60)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(MinidiscColors.accent)
            }

            VStack(spacing: MinidiscSpacing.xs) {
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(MinidiscColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(MinidiscColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, MinidiscSpacing.xxxl)

            progressDots
        }
        .padding(.top, MinidiscSpacing.xxl)
        .padding(.bottom, MinidiscSpacing.l)
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: MinidiscSpacing.s) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == stepIndex ? MinidiscColors.accent : Color.secondary.opacity(0.3))
                    .frame(width: i == stepIndex ? 20 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: stepIndex)
            }
        }
    }

    // MARK: - Bottom actions

    private var bottomActions: some View {
        VStack(spacing: MinidiscSpacing.m) {
            Button(action: onContinue) {
                Text(continueLabel)
                    .font(.system(.body, design: .default, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MinidiscColors.accent)

            Button("Skip", action: onSkip)
                .font(.subheadline)
                .foregroundStyle(MinidiscColors.textSecondary)
        }
        .padding(.horizontal, MinidiscSpacing.xxxl)
        .padding(.top, MinidiscSpacing.l)
        .padding(.bottom, MinidiscSpacing.xxl)
        .background(.regularMaterial)
    }
}
