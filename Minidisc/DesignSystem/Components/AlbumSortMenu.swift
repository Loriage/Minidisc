import SwiftUI

struct AlbumSortMenu: View {
    @Binding var sort: AlbumSort
    var iconOnly: Bool = false

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(AlbumSort.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityLabel("Sort albums: \(sort.label)")
            } else {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
            }
        }
    }
}
