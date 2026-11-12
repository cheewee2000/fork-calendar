import Foundation
import SwiftUI

extension Calendar {
    func startOfWeek(for date: Date) -> Date {
        self.date(from: dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    }

    func week(containing date: Date) -> [Date] {
        let start = startOfWeek(for: date)
        return (0..<7).compactMap { self.date(byAdding: .day, value: $0, to: start) }
    }

    /// 6-week grid covering the month containing `date`.
    func monthGrid(for date: Date) -> [Date] {
        guard let monthStart = self.date(from: dateComponents([.year, .month], from: date)) else { return [] }
        let gridStart = startOfWeek(for: monthStart)
        return (0..<42).compactMap { self.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// The 1st of a month within the 7 days starting at `weekStart`, if any.
    func firstOfMonth(inWeekStarting weekStart: Date) -> Date? {
        (0..<7).lazy.compactMap { self.date(byAdding: .day, value: $0, to: weekStart) }
            .first { self.component(.day, from: $0) == 1 }
    }

    /// Wall-clock hours from midnight of `day` to `date` (24 at or past the
    /// next midnight). Clock components, not elapsed seconds, so a 23/25-hour
    /// DST day still lines up with the 24-slot grid.
    func wallHours(of date: Date, in day: Date) -> Double {
        let dayStart = startOfDay(for: day)
        if date <= dayStart { return 0 }
        if date >= self.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400) { return 24 }
        let c = dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    /// Inverse of `wallHours`: the instant at wall-clock `hours` on `day`.
    func date(atWallHours hours: Double, in day: Date) -> Date {
        let dayStart = startOfDay(for: day)
        if hours >= 24 { return self.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400) }
        let total = Int((hours * 3600).rounded())
        return self.date(bySettingHour: total / 3600, minute: total % 3600 / 60, second: total % 60, of: dayStart)
            ?? dayStart.addingTimeInterval(hours * 3600)
    }

    func orderedVeryShortWeekdaySymbols() -> [String] {
        let symbols = veryShortWeekdaySymbols
        let first = firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

extension Date {
    func isSameDay(as other: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }
}

enum Fmt {
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    static let hour: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()
    static let dayNum: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()
    static let interval: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    static let month: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    /// Cached formatters keep the zone they were built in; re-point them
    /// after a system time-zone change.
    static func resetTimeZones() {
        for f in [monthYear, time, hour, dayNum, month, dateTime, weekdayShort] { f.timeZone = .current }
        interval.timeZone = .current
    }
}
