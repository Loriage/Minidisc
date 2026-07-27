// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

extension Int {
    func plural(_ singular: String, _ plural: String) -> String {
        let noun = self == 1 ? singular : plural
        return "\(self) \(String(localized: String.LocalizationValue(noun)))"
    }
}
