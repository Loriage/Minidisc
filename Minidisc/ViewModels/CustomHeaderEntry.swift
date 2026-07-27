import Foundation

struct CustomHeaderEntry: Identifiable {
    let id: UUID
    var key: String
    var value: String

    init(key: String = "", value: String = "") {
        self.id = UUID()
        self.key = key
        self.value = value
    }
}
