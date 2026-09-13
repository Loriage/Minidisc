import SwiftUI

struct SongSortMenu: View {
    @Binding var sort: SongSort

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(SongSort.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
        }
    }
}
