import SwiftUI
import UIKit

struct OnboardingWelcomeView: View {
    let onServerConnected: () -> Void

    @Environment(\.appContainer) private var container
    @State private var viewModel: OnboardingViewModel?
    @State private var showingServerForm = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            MinidiscColors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                AnimatedMinidiscHero()
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .animation(.spring(duration: 0.6, bounce: 0.4), value: appeared)

                Spacer().frame(height: MinidiscSpacing.xxxxl)

                VStack(spacing: MinidiscSpacing.m) {
                    Text("Your music.\nYour rules.")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(MinidiscColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.05), value: appeared)

                    Text("Stream your library from your own server.\nNo subscriptions. No big tech.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(MinidiscColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.1), value: appeared)
                }
                .padding(.horizontal, MinidiscSpacing.xxxl)

                Spacer()

                getStartedButton
                    .padding(.horizontal, MinidiscSpacing.xxxl)
                    .padding(.bottom, MinidiscSpacing.xxxl)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 30)
                    .animation(.spring(duration: 0.5, bounce: 0.3).delay(0.2), value: appeared)
            }
        }
        .onAppear {
            guard viewModel == nil, let container else { return }
            viewModel = OnboardingViewModel(serverService: container.serverService)
            appeared = true
        }
        .onChange(of: container?.serverState.activeServer != nil) { _, connected in
            if connected { showingServerForm = false }
        }
        .sheet(isPresented: $showingServerForm, onDismiss: {
            if container?.serverState.activeServer != nil {
                onServerConnected()
            }
        }) {
            if let viewModel {
                NavigationStack {
                    ServerFormView(viewModel: viewModel)
                }
            }
        }
    }

    private var getStartedButton: some View {
        Button {
            triggerHaptic()
            showingServerForm = true
        } label: {
            Text("Get Started")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(MinidiscColors.accent)
        .disabled(viewModel == nil)
    }

    private func triggerHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - Animated Minidisc Hero

private struct AnimatedMinidiscHero: View {
    @State private var discAngle: Double = 0

    private let side: CGFloat = 180
    private var w: CGFloat { side }
    private var h: CGFloat { side }

    private var rect: CGRect { CGRect(x: 0, y: 0, width: w, height: h) }
    private var discR: CGFloat { MinidiscCartridgeIcon.windowRadius(in: rect) }

    /// Shutter: the metal band at mid-height, overlapping the disc as it does on the real cartridge —
    /// it slides over the window rather than sitting beside it. Flush with the shell's trailing edge.
    private var shutterSize: CGSize { CGSize(width: w * 0.42, height: h * 0.27) }
    private var shutterOffset: CGSize {
        CGSize(width: w - shutterSize.width / 2 - w / 2, height: 0)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(MinidiscColors.accent.opacity(0.08))
                .frame(width: 290, height: 290)
                .blur(radius: 60)

            disc
                .rotationEffect(.degrees(discAngle))
                .frame(width: w, height: h)

            MinidiscCartridgeIcon()
                .fill(MinidiscColors.backgroundTertiary, style: FillStyle(eoFill: true))
                .frame(width: w, height: h)

            // The window rim goes under the shutter — stroking the whole icon here would run this
            // circle straight across the band.
            Circle()
                .stroke(MinidiscColors.accent.opacity(0.65), lineWidth: 1.5)
                .frame(width: discR * 2, height: discR * 2)

            shutter
                .offset(shutterOffset)

            // Drawn last so the shell's own border runs over the shutter: the band is flush with the
            // trailing edge, and its fill would otherwise eat the inner half of that stroke.
            MinidiscCartridgeShell()
                .stroke(MinidiscColors.accent.opacity(0.65), lineWidth: 1.5)
                .frame(width: w, height: h)
        }
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) {
                discAngle = 360
            }
        }
    }

    /// The disc itself: hub plus three arcs of data surface, so the rotation reads.
    private var disc: some View {
        ZStack {
            Circle()
                .fill(MinidiscColors.backgroundPrimary)
                .frame(width: discR * 2, height: discR * 2)

            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(MinidiscColors.accent.opacity(0.5), lineWidth: 1)
                    .frame(width: discR * 1.3, height: discR * 1.3)
                    .rotationEffect(.degrees(Double(i) * 120))
            }

            Circle()
                .fill(MinidiscColors.accentBackground)
                .frame(width: discR * 0.5, height: discR * 0.5)
            Circle()
                .stroke(MinidiscColors.accent.opacity(0.6), lineWidth: 1)
                .frame(width: discR * 0.5, height: discR * 0.5)
        }
    }

    private var shutter: some View {
        UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2)
            .fill(MinidiscColors.backgroundTertiary)
            .frame(width: shutterSize.width, height: shutterSize.height)
            .overlay {
                ShutterOutline(radius: 2)
                    .stroke(MinidiscColors.accent.opacity(0.5), lineWidth: 1.5)
            }
    }
}

/// Three-sided outline for the shutter. The trailing side is left open: the band sits flush against
/// the shell, whose own border already draws that edge — closing it here would double the line.
private struct ShutterOutline: Shape {
    let radius: CGFloat

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
