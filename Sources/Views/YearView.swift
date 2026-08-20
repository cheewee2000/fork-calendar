import SwiftUI

/// Whole year as a stack of weeks — one row per week, 7 columns, event dots.
struct YearView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    private let gutter: CGFloat = 38

    var body: some View {
        let cal = appState.calendar
        let year = cal.component(.year, from: appState.currentDate)
        let weeks = yearWeeks(year: year, calendar: cal)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(CWT.mono(9, .semibold))
                        .foregroundStyle(CWT.inkSoft)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 3)
            Divider()
            GeometryReader { geo in
                let rowH = max(15, geo.size.height / CGFloat(weeks.count))
                let needsScroll = rowH * CGFloat(weeks.count) > geo.size.height + 1
                let content = VStack(spacing: 0) {
                    ForEach(weeks, id: \.self) { weekStart in
                        YearWeekRow(weekStart: weekStart, year: year, rowH: rowH, gutter: gutter)
                    }
                }
                if needsScroll {
                    ScrollView { content }
                } else {
                    content
                }
            }
        }
    }

    private func yearWeeks(year: Int, calendar: Calendar) -> [Date] {
        guard let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let dec31 = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return [] }
        var result: [Date] = []
        var day = calendar.startOfWeek(for: jan1)
        while day <= dec31 {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 7, to: day) else { break }
            day = next
        }
        return result
    }
}

private struct YearWeekRow: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let weekStart: Date
    let year: Int
    let rowH: CGFloat
    let gutter: CGFloat

    var body: some View {
        let cal = appState.calendar
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        HStack(spacing: 0) {
            Text(monthLabel(calendar: cal))
                .font(CWT.mono(9, .semibold))
                .foregroundStyle(CWT.inkSoft)
                .frame(width: gutter, alignment: .leading)
                .padding(.leading, 6)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        YearDayCell(day: day, year: year, rowH: rowH)
                    }
                }
                // All-day/multi-day events as compact bars along the row bottom
                GeometryReader { geo in
                    let cellW = geo.size.width / 7
                    let barH: CGFloat = rowH >= 26 ? 9 : 4
                    let laneCap = rowH >= 38 ? 2 : 1
                    let bars = SpanLayout.bars(days: days, store: store, calendar: cal)
                        .filter { $0.lane < laneCap }
                    ForEach(bars) { bar in
                        YearSpanChip(event: bar.event, showTitle: barH >= 8)
                            .frame(width: CGFloat(bar.endIndex - bar.startIndex + 1) * cellW - 3, height: barH)
                            .offset(
                                x: CGFloat(bar.startIndex) * cellW + 1.5,
                                y: rowH - 1.5 - barH - CGFloat(bar.lane) * (barH + 1)
                            )
                    }
                }
            }
        }
        .frame(height: rowH)
    }

    /// Show the month name on the row containing the 1st of that month.
    private func monthLabel(calendar: Calendar) -> String {
        for offset in 0..<7 {
            if let day = calendar.date(byAdding: .day, value: offset, to: weekStart),
               calendar.component(.day, from: day) == 1,
               calendar.component(.year, from: day) == year {
                let f = DateFormatter()
                f.setLocalizedDateFormatFromTemplate("MMM")
                return f.string(from: day)
            }
        }
        return ""
    }
}

private struct YearSpanChip: View {
    @EnvironmentObject var appState: AppState
    let event: CalEvent
    let showTitle: Bool

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        Group {
            if showTitle {
                Text(event.title ?? "Untitled")
                    .font(CWT.mono(7, .medium))
                    .lineLimit(1)
                    .foregroundStyle(color)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(Rectangle().fill(color.opacity(0.22)))
            } else {
                Rectangle().fill(color.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.select(event) }
    }
}

private struct YearDayCell: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let day: Date
    let year: Int
    let rowH: CGFloat

    var body: some View {
        let cal = appState.calendar
        let inYear = cal.component(.year, from: day) == year
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let evenMonth = cal.component(.month, from: day) % 2 == 0

        HStack(spacing: 3) {
            Text(Fmt.dayNum.string(from: day))
                .font(CWT.mono(9, isToday ? .bold : .regular))
                .frame(width: 16, height: 13)
                .background { if isToday { Rectangle().fill(CWT.signalRed) } }
                .foregroundStyle(isToday ? Color.white : inYear ? Color.primary : CWT.inkSoft.opacity(0.35))
            Spacer(minLength: 0)
        }
        .padding(.leading, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(inYear && evenMonth ? CWT.paper3.opacity(0.55) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(CWT.ruleSoft).frame(height: 0.5)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(CWT.ruleSoft).frame(width: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.goTo(day)
            appState.setViewMode(.day)
        }
    }
}
