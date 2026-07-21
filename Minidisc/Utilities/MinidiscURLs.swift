// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

enum MinidiscURLs {
    /// This fork's own repository — Settings' share / GitHub / issues entries.
    static let repo = URL(string: "https://github.com/Loriage/Minidisc")!
    static let repoIssues = URL(string: "https://github.com/Loriage/Minidisc/issues")!
    /// The upstream project Minidisc forked from — Acknowledgements only.
    static let cassette = URL(string: "https://github.com/CassetteLab/cassette")!
    static let swiftSonic = URL(string: "https://github.com/CassetteLab/swiftsonic")!
    static let navidrome = URL(string: "https://www.navidrome.org")!
    static let openSubsonic = URL(string: "https://opensubsonic.netlify.app")!
    static let audioStreaming = URL(string: "https://github.com/dimitris-c/AudioStreaming")!
    static let listenBrainz = URL(string: "https://listenbrainz.org")!
}
