import SwiftUI

/// Section label in SF Pro Rounded semibold. Use above lists or grids in detail screens.
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
