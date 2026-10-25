import Foundation

enum FGCalendar {
    // Calendar presentation is local; the shared protocol always keeps the
    // original UTC timestamp and annual flag unchanged.
    static func occurrence(_ timestamp: Int64, annual: Bool, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date {
        let original = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        guard annual, original < now else { return original }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: original)
        guard let month = parts.month, let day = parts.day, let currentYear = calendar.dateComponents([.year], from: now).year else { return original }
        for year in currentYear...(currentYear + 8) {
            var start = DateComponents(); start.year = year; start.month = month; start.day = 1
            guard let first = calendar.date(from: start), let days = calendar.range(of: .day, in: .month, for: first) else { continue }
            var candidate = parts
            candidate.year = year; candidate.day = min(day, days.count)
            if let date = calendar.date(from: candidate), date >= now { return date }
        }
        return original
    }
}
