import SwiftUI

struct LidarrTagsField: View {
    let tags: [LidarrTag]
    @Binding var selection: Set<Int>

    var body: some View {
        NavigationLink {
            LidarrTagSelectionView(tags: tags, selection: $selection)
        } label: {
            LabeledContent("Tags") {
                if selection.isEmpty {
                    Text("None")
                } else {
                    Text(tags.filter { selection.contains($0.id) }.map(\.label), format: .list(type: .and))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier("lidarr.tags")
    }
}

private struct LidarrTagSelectionView: View {
    let tags: [LidarrTag]
    @Binding var selection: Set<Int>

    var body: some View {
        List {
            if tags.isEmpty {
                Text("No tags are configured in Lidarr.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tags) { tag in
                    Button {
                        if selection.contains(tag.id) {
                            selection.remove(tag.id)
                        } else {
                            selection.insert(tag.id)
                        }
                    } label: {
                        HStack {
                            Text(tag.label)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if selection.contains(tag.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.minidiscAccent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(selection.contains(tag.id) ? .isSelected : [])
                    .accessibilityIdentifier("lidarr.tag.\(tag.id)")
                }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayModeInline()
    }
}
