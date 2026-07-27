import Foundation

extension Int {
    func plural(_ singular: String, _ plural: String) -> String {
        let noun = self == 1 ? singular : plural
        return "\(self) \(String(localized: String.LocalizationValue(noun)))"
    }
}
