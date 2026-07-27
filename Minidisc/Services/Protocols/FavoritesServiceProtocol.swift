// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

protocol FavoritesServiceProtocol: AnyObject {
    func star(itemType: FavoriteType, itemId: String) async throws
    func unstar(itemType: FavoriteType, itemId: String) async throws
    func syncFromServer() async throws
    func isFavorite(itemType: FavoriteType, itemId: String) -> Bool
}
