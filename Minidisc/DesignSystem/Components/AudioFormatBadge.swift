import SwiftUI

struct AudioFormatBadge: View {
    let format: String
    var color: Color = Color.minidiscAccent

    var body: some View {
        Text(format.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
            .accessibilityLabel(format)
    }
}
