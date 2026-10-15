import SwiftUI

/// Separates the discs of a multi-disc album in a track list.
struct DiscHeader: View {
    let discNumber: Int
    var title: String?

    var body: some View {
        HStack(spacing: MinidiscSpacing.s) {
            Image(systemName: "opticaldisc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Disc \(discNumber)")
                .font(.minidiscSectionTitle)
            if let title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.minidiscCellSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MinidiscSpacing.l)
        .padding(.top, MinidiscSpacing.l)
        .padding(.bottom, MinidiscSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview {
    DiscHeader(discNumber: 2, title: "Live at the Fillmore")
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}
