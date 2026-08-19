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
    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}
