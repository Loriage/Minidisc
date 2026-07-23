// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct CrossfadeSettingsSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        let cf = container?.crossfadeSettings
        let duration = cf?.duration ?? 0

        Section {
            Stepper(
                value: Binding(
                    get: { cf?.duration ?? 0 },
                    set: { newVal in
                        cf?.duration = newVal
                        Task { await container?.playerService.crossfadeSettingsDidChange() }
                    }
                ),
                in: 0...5,
                step: 0.5
            ) {
                HStack {
                    Label("Duration", systemImage: "timer")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(crossfadeDurationLabel(duration))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .font(.body.weight(.medium))
                }
            }

            if duration > 0 {
                Toggle(isOn: Binding(
                    get: { cf?.disableForGapless ?? true },
                    set: { newVal in
                        cf?.disableForGapless = newVal
                        Task { await container?.playerService.crossfadeSettingsDidChange() }
                    }
                )) {
                    Label("Disable for gapless albums", systemImage: "music.note.list")
                        .foregroundStyle(.primary)
                }
                .tint(Color(.systemGreen))
            }
        } header: {
            Text("Crossfade")
        } footer: {
            Text("Fades one track into the next over the set time. Set Off for no fade. The toggle keeps gapless albums and live mixes seamless.")
        }
    }

    private func crossfadeDurationLabel(_ seconds: Double) -> String {
        seconds == 0 ? "Off" : "\(String(format: "%.1f", seconds)) s"
    }
}
