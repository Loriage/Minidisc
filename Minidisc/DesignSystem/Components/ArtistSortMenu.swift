import SwiftUI

/// The sort control for the artists list, bound to the caller's persisted `@AppStorage("minidisc.artistSort")`.
struct ArtistSortMenu: View {
    @Binding var sort: ArtistSort

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(ArtistSort.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
        }
    }
}
