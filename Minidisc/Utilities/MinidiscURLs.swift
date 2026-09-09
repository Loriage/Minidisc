import Foundation

enum MinidiscURLs {
    /// Let the recipient's App Store choose the storefront and available localization.
    static let appStore = URL(string: "https://apps.apple.com/app/id6794636813")!
    /// This fork's own repository — Settings' GitHub / issues entries.
    static let repo = URL(string: "https://github.com/Loriage/Minidisc")!
    static let repoIssues = URL(string: "https://github.com/Loriage/Minidisc/issues")!
    /// The upstream project Minidisc forked from — Acknowledgements only.
    static let cassette = URL(string: "https://github.com/CassetteLab/cassette")!
    static let swiftSonic = URL(string: "https://github.com/CassetteLab/swiftsonic")!
    static let navidrome = URL(string: "https://www.navidrome.org")!
    static let openSubsonic = URL(string: "https://opensubsonic.netlify.app")!
    static let listenBrainz = URL(string: "https://listenbrainz.org")!
}
