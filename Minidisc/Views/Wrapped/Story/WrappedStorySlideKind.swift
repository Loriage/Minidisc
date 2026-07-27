// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// The ordered set of slides shown in the annual Wrapped story player.
nonisolated enum WrappedStorySlideKind: String, CaseIterable, Sendable {
    case intro        = "Intro"
    case minutes      = "Minutes"
    case topTrack     = "Top Track"
    case topArtist    = "Top Artist"
    case topAlbum     = "Top Album"
    case topGenre     = "Top Genre"
    case discoveries  = "Discoveries"
    case closing      = "Closing"
}
