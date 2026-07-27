import SwiftUI

struct AudioFormatBadge: View {
    let format: String
    var color: Color = Color.minidiscAccent

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
            .accessibilityLabel(format)
    }
}
