import Foundation

nonisolated enum WrappedAvailability {

    static func isAnnualAvailable(
        year: Int,
        currentDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let threshold = calendar.date(from: DateComponents(year: year, month: 12, day: 28)) else {
            return false
        }
        return currentDate >= threshold
    }
}
