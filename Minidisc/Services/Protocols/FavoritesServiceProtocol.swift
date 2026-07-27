import Foundation

protocol FavoritesServiceProtocol: AnyObject {
    func star(itemType: FavoriteType, itemId: String) async throws
    func unstar(itemType: FavoriteType, itemId: String) async throws
    func syncFromServer() async throws
    func isFavorite(itemType: FavoriteType, itemId: String) -> Bool
}
