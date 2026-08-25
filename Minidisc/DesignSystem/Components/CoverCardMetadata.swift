import SwiftUI

/// Shared type hierarchy for metadata displayed directly below cover artwork.
struct CoverCardMetadata: View {
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.minidiscCellTitle)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.minidiscCaption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.minidiscCaption2)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
