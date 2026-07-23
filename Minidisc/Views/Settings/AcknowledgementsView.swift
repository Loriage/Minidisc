// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Licenses and credits, linked from Settings → About.
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section("License") {
                LabeledContent("Minidisc") {
                    Text("Mozilla Public License 2.0")
                }
            }

            Section("Open Source") {
                Button {
                    ExternalLinkOpener.open(MinidiscURLs.swiftSonic)
                } label: {
                    LabeledContent("SwiftSonic") {
                        Text("MIT License")
                    }
                }
                .foregroundStyle(.primary)
            }

            Section {
                Button {
                    ExternalLinkOpener.open(MinidiscURLs.cassette)
                } label: {
                    Text("Cassette")
                }
                .foregroundStyle(.primary)
                Button {
                    ExternalLinkOpener.open(MinidiscURLs.navidrome)
                } label: {
                    Text("Navidrome")
                }
                .foregroundStyle(.primary)
                Button {
                    ExternalLinkOpener.open(MinidiscURLs.openSubsonic)
                } label: {
                    Text("OpenSubsonic")
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Thanks")
            } footer: {
                Text("This app is a fork of Cassette, originally built by Mathieu Dubart. Thanks to the Navidrome team for an excellent self-hosted music server, and to the OpenSubsonic community for modernizing the Subsonic API.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
