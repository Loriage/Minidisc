// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct ReplayGainSettingsSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        let rg = container?.replayGainSettings

        Section("Playback") {
            Toggle(isOn: Binding(
                get: { rg?.enabled ?? false },
                set: { newVal in
                    rg?.enabled = newVal
                    Task { await container?.playerService.replayGainSettingsDidChange() }
                }
            )) {
                Label("ReplayGain", systemImage: "speaker.wave.3")
                    .foregroundStyle(.primary)
            }
            .tint(Color(.systemGreen))

            if rg?.enabled == true {
                Picker(selection: Binding(
                    get: { rg?.mode ?? .track },
                    set: { newVal in
                        rg?.mode = newVal
                        Task { await container?.playerService.replayGainSettingsDidChange() }
                    }
                )) {
                    Text("Track").tag(ReplayGainMode.track)
                    Text("Album").tag(ReplayGainMode.album)
                } label: {
                    Label("Mode", systemImage: "music.note")
                        .foregroundStyle(.primary)
                }
                .pickerStyle(.menu)
                .tint(.secondary)

                Stepper(
                    value: Binding(
                        get: { rg?.preAmp ?? 0 },
                        set: { newVal in
                            rg?.preAmp = newVal
                            Task { await container?.playerService.replayGainSettingsDidChange() }
                        }
                    ),
                    in: ReplayGainSettings.minPreAmp...ReplayGainSettings.maxPreAmp,
                    step: 0.5
                ) {
                    HStack {
                        Label("Pre-amp", systemImage: "slider.horizontal.3")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(preAmpLabel(rg?.preAmp ?? 0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.body.weight(.medium))
                    }
                }

                Toggle(isOn: Binding(
                    get: { rg?.preventClipping ?? true },
                    set: { newVal in
                        rg?.preventClipping = newVal
                        Task { await container?.playerService.replayGainSettingsDidChange() }
                    }
                )) {
                    Label("Prevent clipping", systemImage: "waveform.path.ecg")
                        .foregroundStyle(.primary)
                }
                .tint(Color(.systemGreen))
            }
        }
    }

    private func preAmpLabel(_ dB: Double) -> String {
        let sign = dB > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", dB)) dB"
    }
}
