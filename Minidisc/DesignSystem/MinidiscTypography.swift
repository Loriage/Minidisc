import SwiftUI

// MARK: - Typography tokens
// Plain SF Pro throughout; hierarchy comes from size and weight, not from a second design.
// All tokens are built on text styles so they follow Dynamic Type.

extension Font {
    // MARK: Headings

    /// Artist name over the hero image.
    static let minidiscHeroTitle = Font.system(.largeTitle, weight: .bold)

    /// Track title in the full player.
    static let minidiscPlayerTitle = Font.system(.title2, weight: .bold)

    /// Artist line under the player title.
    static let minidiscPlayerSubtitle = Font.system(.title3, weight: .regular)

    /// Album line under the player artist.
    static let minidiscPlayerTertiary = Font.system(.callout, weight: .regular)

    /// Album or playlist name in a detail header.
    static let minidiscDetailTitle = Font.system(.title2, weight: .bold)

    /// Artist or owner under a detail title.
    static let minidiscDetailSubtitle = Font.system(.body, weight: .medium)

    /// Section headers in scroll views (disc headers, compact titles).
    static let minidiscSectionTitle = Font.system(.headline, weight: .semibold)

    /// Carousel / shelf headers ("More from…", "Similar Artists").
    static let minidiscShelfTitle = Font.system(.title3, weight: .bold)

    // MARK: Body & cells

    static let minidiscBody = Font.system(.body, weight: .regular)

    static let minidiscCellTitle = Font.system(.callout, weight: .semibold)

    static let minidiscCellSubtitle = Font.system(.subheadline, weight: .regular)

    /// Track titles in album and playlist lists.
    static let minidiscTrackTitle = Font.system(.body, weight: .regular)

    /// Track numbers and durations: tabular so columns line up.
    static let minidiscTrackNumber = Font.system(.subheadline, weight: .regular).monospacedDigit()

    /// Release metadata (year · songs · duration) and player format line.
    static let minidiscMetadata = Font.system(.footnote, weight: .regular).monospacedDigit()

    /// Format badges (FLAC, MP3) and other short all-caps labels.
    static let minidiscBadge = Font.system(.caption2, weight: .bold)

    static let minidiscCaption = Font.system(.caption, weight: .regular)

    static let minidiscCaption2 = Font.system(.caption2, weight: .regular)

    // MARK: Lyrics

    static let minidiscLyricsLine = Font.system(.title, weight: .bold)
}
