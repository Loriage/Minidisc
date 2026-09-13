import SwiftUI

// MARK: - Typography tokens
// Use Rounded for prominent headings and Default for body text, cells and captions.

extension Font {
    // MARK: Headings (SF Pro Rounded)

    static let minidiscPlayerTitle = Font.system(.title, design: .rounded, weight: .bold)

    static let minidiscDetailTitle = Font.system(.title2, design: .rounded, weight: .semibold)

    static let minidiscSectionTitle = Font.system(.headline, design: .rounded, weight: .semibold)

    static let minidiscShelfTitle = Font.system(.title2, design: .rounded, weight: .bold)

    // MARK: Body & cells (SF Pro Default)

    static let minidiscBody = Font.system(.body, design: .default, weight: .regular)

    static let minidiscCellTitle = Font.system(.callout, design: .default, weight: .semibold)

    static let minidiscCellSubtitle = Font.system(.subheadline, design: .default, weight: .regular)

    static let minidiscCaption = Font.system(.caption, design: .default, weight: .regular)

    static let minidiscCaption2 = Font.system(.caption2, design: .default, weight: .regular)

    // MARK: Lyrics

    static let minidiscLyricsLine = Font.system(.title, design: .rounded, weight: .semibold)
}
