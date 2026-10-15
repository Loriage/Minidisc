import SwiftUI

/// A small capsule for release facets under an album header: genres and record labels.
struct MetadataChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: MinidiscSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(.minidiscMetadata.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, MinidiscSpacing.m)
        .padding(.vertical, MinidiscSpacing.s - 2)
        .background(Capsule().fill(.primary.opacity(0.12)))
    }
}

/// Lays chips out in centred rows, wrapping when they don't fit (long genres, large text).
struct MetadataChipFlow: Layout {
    var spacing: CGFloat = MinidiscSpacing.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: .init(width: min(size.width, bounds.width), height: size.height)
                )
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: maxWidth, height: nil))
            let itemWidth = min(size.width, maxWidth)
            let proposedWidth = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if !current.indices.isEmpty, proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    HStack {
        MetadataChip(text: "Alternative Rock")
        MetadataChip(text: "Kong", systemImage: "building.2")
    }
    .padding()
    .background(Color.black)
    .environment(\.colorScheme, .dark)
}
