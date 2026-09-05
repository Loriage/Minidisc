import SwiftUI

struct PlaylistCoverCarousel: View {
    let title: String
    let selectedGradient: PlaylistGradientShape?
    let isPhotoSelected: Bool
    var photoPreview: PlatformImage? = nil
    var showsPhotoOption: Bool = true
    var leadingLabel: LocalizedStringKey = "None"
    var leadingCoverArtId: String? = nil
    let onSelectLeading: () -> Void
    var onSelectPhoto: () -> Void = {}
    var onRequestPhotoPicker: () -> Void = {}
    let onSelectGradient: (PlaylistGradientShape) -> Void

    @State private var scrolledOption: CoverOption?

    enum CoverOption: Hashable {
        case leading
        case photo
        case gradient(PlaylistGradientShape)

        var accessibilityIdentifier: String {
            let suffix: String
            switch self {
            case .leading: suffix = "current"
            case .photo: suffix = "photo"
            case .gradient(let shape): suffix = shape.rawValue
            }
            return "playlist.cover.option.\(suffix)"
        }
    }

    private var options: [CoverOption] {
        var opts: [CoverOption] = [.leading]
        if showsPhotoOption { opts.append(.photo) }
        opts += PlaylistGradientShape.selectable.map { .gradient($0) }
        return opts
    }

    private var selectedOption: CoverOption {
        if let selectedGradient { return .gradient(selectedGradient) }
        if isPhotoSelected { return .photo }
        return .leading
    }

    var cardFraction: CGFloat = 0.74

    var body: some View {
        VStack(spacing: MinidiscSpacing.m) {
            GeometryReader { geo in
                let cardSize = geo.size.width * cardFraction
                let sidePeek = max(0, (geo.size.width - cardSize) / 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MinidiscSpacing.m) {
                        ForEach(options, id: \.self) { option in
                            card(option)
                                .frame(width: cardSize, height: cardSize)
                                .id(option)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, sidePeek, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrolledOption)
            }
            .aspectRatio(1 / cardFraction, contentMode: .fit)

            dotRow
        }
        .onAppear { scrolledOption = selectedOption }
        .onChange(of: scrolledOption) { _, option in
            guard let option, option != selectedOption else { return }
            commitSelection(option)
        }
    }

    @ViewBuilder
    private func card(_ option: CoverOption) -> some View {
        ZStack {
            switch option {
            case .leading:
                if let leadingCoverArtId {
                    CoverArtView(id: leadingCoverArtId, size: 600)
                } else {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "nosign")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            case .photo:
                if let photoPreview {
                    platformImage(photoPreview)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Color.secondary.opacity(0.12)
                    Circle()
                        .fill(Color.minidiscAccent)
                        .frame(width: 72, height: 72)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                }
            case .gradient(let shape):
                PlaylistGradientView(spec: .neutral(shape: shape))
                titleOverlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
        .onTapGesture { handleTap(option) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: option))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(option == selectedOption ? .isSelected : [])
        .accessibilityValue(option == selectedOption ? Text("Selected") : Text(""))
        .accessibilityIdentifier(option.accessibilityIdentifier)
    }

    private func accessibilityLabel(for option: CoverOption) -> Text {
        switch option {
        case .leading: Text(leadingLabel)
        case .photo: Text("Choose from Library")
        case .gradient(let shape): Text(shape.displayName)
        }
    }

    private func handleTap(_ option: CoverOption) {
        withAnimation(.snappy) { scrolledOption = option }
        if case .photo = option { onRequestPhotoPicker() }
    }

    private var titleOverlay: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                Text(title.isEmpty ? "Playlist Title" : title)
                    .font(.system(size: geo.size.height * 0.15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(title.isEmpty ? 0.6 : 1))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, geo.size.height * 0.09)
            .padding(.top, geo.size.height * 0.30)
        }
    }

    private var dotRow: some View {
        ZStack {
            HStack(spacing: 7) {
                ForEach(options, id: \.self) { option in
                    Circle()
                        .fill(option == selectedOption ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
        }
    }

    private func commitSelection(_ option: CoverOption) {
        switch option {
        case .leading: onSelectLeading()
        case .photo: onSelectPhoto()
        case .gradient(let shape): onSelectGradient(shape)
        }
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        Image(uiImage: image)
    }
}
