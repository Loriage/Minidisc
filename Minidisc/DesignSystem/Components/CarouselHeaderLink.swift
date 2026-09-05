import SwiftUI

enum MinidiscCarouselMetrics {
    static let previewLimit = 10
    static let artistArtwork: CGFloat = 104
}

/// The shared edge-to-edge horizontal shelf used by the Home feed and detail-page recommendations.
struct MinidiscShelf<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            header()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MinidiscSpacing.m) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.horizontal, MinidiscSpacing.l)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct MinidiscCarouselHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let title: Text
    private let showsChevron: Bool
    private let horizontalPadding: CGFloat

    init(
        _ title: LocalizedStringResource,
        showsChevron: Bool,
        horizontalPadding: CGFloat = MinidiscSpacing.l
    ) {
        self.title = Text(title)
        self.showsChevron = showsChevron
        self.horizontalPadding = horizontalPadding
    }

    fileprivate init(
        title: Text,
        showsChevron: Bool,
        horizontalPadding: CGFloat
    ) {
        self.title = title
        self.showsChevron = showsChevron
        self.horizontalPadding = horizontalPadding
    }

    var body: some View {
        HStack(alignment: .center, spacing: MinidiscSpacing.s) {
            title
                .font(.minidiscShelfTitle)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

            Spacer(minLength: MinidiscSpacing.s)

            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, MinidiscSpacing.xs)
    }
}

/// A shelf title that becomes a full-width navigation link when the shelf has hidden content.
struct MinidiscCarouselHeaderLink<Destination: View>: View {
    private let title: Text
    private let horizontalPadding: CGFloat
    private let destination: Destination
    private let showsNavigation: Bool

    init(
        _ title: LocalizedStringResource,
        itemCount: Int,
        visibleLimit: Int = MinidiscCarouselMetrics.previewLimit,
        hasMore: Bool = false,
        horizontalPadding: CGFloat = MinidiscSpacing.l,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = Text(title)
        self.horizontalPadding = horizontalPadding
        self.destination = destination()
        showsNavigation = itemCount > visibleLimit || hasMore
    }

    init(
        verbatim title: String,
        itemCount: Int,
        visibleLimit: Int = MinidiscCarouselMetrics.previewLimit,
        hasMore: Bool = false,
        horizontalPadding: CGFloat = MinidiscSpacing.l,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = Text(verbatim: title)
        self.horizontalPadding = horizontalPadding
        self.destination = destination()
        showsNavigation = itemCount > visibleLimit || hasMore
    }

    @ViewBuilder
    var body: some View {
        if showsNavigation {
            NavigationLink {
                destination
            } label: {
                header(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("See all")
        } else {
            header(showsChevron: false)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func header(showsChevron: Bool) -> some View {
        MinidiscCarouselHeader(
            title: title,
            showsChevron: showsChevron,
            horizontalPadding: horizontalPadding
        )
    }
}
