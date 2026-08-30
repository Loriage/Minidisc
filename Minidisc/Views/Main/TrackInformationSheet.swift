import SwiftUI

struct TrackInformationSheet: View {
    let track: DisplayableSong

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Title") {
                        metadataValue(track.title)
                    }

                    if let artist = nonEmpty(track.artist) {
                        LabeledContent("Artist") {
                            metadataValue(artist)
                        }
                    }

                    if let album = nonEmpty(track.albumName) {
                        LabeledContent("Album") {
                            metadataValue(album)
                        }
                    }

                    if let genre = nonEmpty(track.genre) {
                        LabeledContent("Genre") {
                            metadataValue(genre)
                        }
                    }

                    if let format = nonEmpty(track.audioFormat) {
                        LabeledContent("Format") {
                            Text(format.uppercased())
                        }
                    }

                    if track.duration > 0 {
                        LabeledContent("Duration") {
                            Text(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)))
                        }
                    }

                    if let trackNumber = track.trackNumber {
                        LabeledContent("Track") {
                            Text(trackNumber, format: .number)
                        }
                    }

                    if let discNumber = track.discNumber {
                        LabeledContent("Disc") {
                            Text(discNumber, format: .number)
                        }
                    }
                }
            }
            .navigationTitle("Get Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func metadataValue(_ value: String) -> some View {
        Text(value)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
