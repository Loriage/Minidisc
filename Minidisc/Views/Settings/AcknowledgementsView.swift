import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section("License") {
                LabeledContent("Minidisc") {
                    Text("Mozilla Public License 2.0")
                }
            }

            Section("Open Source") {
                NavigationLink {
                    ScrollView {
                        Text(verbatim: audioLicenses)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle("AudioStreaming")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent("AudioStreaming") {
                        Text("MIT License")
                    }
                }
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

    private var audioLicenses: String {
        guard let url = Bundle.main.url(forResource: "AudioStreaming-Licenses", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
