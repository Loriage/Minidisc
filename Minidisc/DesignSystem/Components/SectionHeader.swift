import SwiftUI

struct SectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.minidiscSectionTitle)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MinidiscSpacing.l)
            .padding(.vertical, MinidiscSpacing.s)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 0) {
        SectionHeader(title: "Albums")
        SectionHeader(title: "Top Tracks")
    }
}
