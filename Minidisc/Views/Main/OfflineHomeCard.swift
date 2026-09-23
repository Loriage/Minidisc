import SwiftUI

struct OfflineHomeCard: View {
    let isManual: Bool
    let songCount: Int
    let isLoading: Bool
    let onDisable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if songCount > 0 {
                NavigationLink(value: HomeDestination.librarySongs) {
                    OfflineHomeStatus(isManual: isManual, songCount: songCount, isLoading: isLoading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Browse music available offline")
            } else {
                OfflineHomeStatus(isManual: isManual, songCount: songCount, isLoading: isLoading)
            }

            if isManual {
                Divider().padding(.horizontal, MinidiscSpacing.l)
                Button(action: onDisable) {
                    Text("Turn Off Offline Mode")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.minidiscAccent)
                .padding(.horizontal, MinidiscSpacing.l)
                .padding(.vertical, MinidiscSpacing.xs)
                .accessibilityIdentifier("home.offline.disable")
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.hero))
        .accessibilityIdentifier("home.offline.card")
    }
}

private struct OfflineHomeStatus: View {
    let isManual: Bool
    let songCount: Int
    let isLoading: Bool

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Image(systemName: "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.minidiscAccent)
                .frame(width: 44, height: 44)
                .background(Color.minidiscAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.large))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Text(isManual ? LocalizedStringKey("Offline Mode") : LocalizedStringKey("You're Offline"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Group {
                    if isLoading && songCount == 0 {
                        Text("Loading…")
                    } else if songCount > 0 {
                        Text("\(songCount) songs available offline")
                    } else {
                        Text("No music saved on this device.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if songCount > 0 {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(MinidiscSpacing.l)
        .contentShape(Rectangle())
    }
}
