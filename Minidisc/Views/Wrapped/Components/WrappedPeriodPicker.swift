import SwiftUI

struct WrappedPeriodPicker: View {
    @Binding var selectedPeriod: WrappedPeriod
    let availablePeriods: [WrappedPeriod]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MinidiscSpacing.xs) {
                ForEach(availablePeriods, id: \.self) { period in
                    let isSelected = period == selectedPeriod
                    Button {
                        selectedPeriod = period
                    } label: {
                        Text(shortLabel(for: period))
                            .font(isSelected ? .minidiscCellTitle : .minidiscCaption)
                            .foregroundStyle(isSelected ? Color.minidiscAccentText : .primary)
                            .padding(.horizontal, MinidiscSpacing.m)
                            .padding(.vertical, MinidiscSpacing.s)
                            .background(isSelected ? Color.minidiscAccent : Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                            .animation(.easeInOut(duration: 0.15), value: isSelected)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, MinidiscSpacing.xs)
        }
        // contentMargins sets scroll insets properly (safe-area aware, trailing pad included)
        .contentMargins(.horizontal, MinidiscSpacing.l, for: .scrollContent)
        // Bleed horizontally past the parent's horizontal padding
        .padding(.horizontal, -MinidiscSpacing.l)
    }

    private func shortLabel(for period: WrappedPeriod) -> String {
        switch period {
        case .year(let year):
            return "\(year)"
        case .month(_, let month):
            return Calendar.current.shortMonthSymbols[month - 1]
        }
    }
}
