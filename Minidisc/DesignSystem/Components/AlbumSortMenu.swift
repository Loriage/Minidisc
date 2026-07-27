import SwiftUI

/// The shared album-sort control: a menu listing the `AlbumSort` options with a checkmark on the active one.
/// Bound to the caller's persisted `@AppStorage("minidisc.albumSort")` preference so every album surface
/// (artist discography, global list) stays in sync.
struct AlbumSortMenu: View {
    @Binding var sort: AlbumSort
    /// When true the label shows just the icon (compact placements like a section-header accessory).
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
