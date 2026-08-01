import Foundation

protocol FavoritesServiceProtocol: AnyObject, Sendable {
    func star(itemType: FavoriteType, itemId: String) async throws
    func unstar(itemType: FavoriteType, itemId: String) async throws
    func syncFromServer() async throws
    @MainActor
    func isFavorite(itemType: FavoriteType, itemId: String) -> Bool
}
