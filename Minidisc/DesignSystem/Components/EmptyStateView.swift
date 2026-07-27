import SwiftUI

/// Uniform empty-state placeholder for list and search screens.
///
/// Usage examples:
/// ```swift
/// EmptyStateView(systemImage: "music.mic", title: "No Artists")
/// EmptyStateView(systemImage: "wifi.slash", title: "You're Offline",
///                subtitle: "Downloaded content is still available.",
///                action: .init(label: "Retry") { Task { await vm.load() } })
/// ```
struct EmptyStateView: View {
    struct Action {
        let label: LocalizedStringKey
        let handler: () -> Void
    }

    let systemImage: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var action: Action? = nil

    var body: some View {
        VStack(spacing: MinidiscSpacing.l) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: MinidiscSpacing.s) {
                Text(title)
                    .font(.minidiscSectionTitle)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.minidiscBody)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            }

            if let action {
                Button(action.label, action: action.handler)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.minidiscAccent)
            }
        }
        .padding(MinidiscSpacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("With action") {
    EmptyStateView(
        systemImage: "magnifyingglass",
        title: "No Results",
        subtitle: "Try a different search term.",
        action: .init(label: "Clear") {}
    )
}

#Preview("Minimal") {
    EmptyStateView(systemImage: "arrow.down.circle", title: "No Downloads")
        .preferredColorScheme(.dark)
}
