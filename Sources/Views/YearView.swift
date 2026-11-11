import SwiftUI

/// Continuous vertically-scrolling year view: one row per week, 7 columns,
/// sized so a whole year fills the viewport. Scrolls across years (today's
/// year −2…+3) like the month view; the header year follows the scroll and
/// navigation (‹ ›, Today) scrolls here.
struct YearView: View {
    @EnvironmentObject var store: CalendarStore
    @Environment(AppState.self) var appState
    @EnvironmentObject var settings: AppSettings

    private let gutter: CGFloat = 38
    /// Week at the top of the viewport (two-way scroll anchor, as MonthView;
    /// seeded at init so the first layout lands on the viewed year).
    @State private var topWeek: Date?

    init(initialWeek: Date?) {
        _topWeek = State(initialValue: initialWeek)
    }

    var body: some View {
        let cal = appState.calendar
        let weeks = allWeeks(calendar: cal)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(CWT.mono(9))
                        .foregroundStyle(CWT.inkSoft)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 3)
            Divider()
            GeometryReader { geo in
                // 53 rows per screen: the year being viewed fills the viewport.
                let rowH = max(15, geo.size.height / 53)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(weeks, id: \.self) { weekStart in
                            YearWeekRow(weekStart: weekStart, rowH: rowH, gutter: gutter)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $topWeek, anchor: .top)
            }
        }
        // Scrolling past mid-year moves the header (and currentDate) to the
        // year that now fills most of the screen.
        .onChange(of: topWeek) {
            guard let shown = shownYear, shown != currentYear,
                  let moved = cal.date(byAdding: .year, value: shown - currentYear, to: appState.currentDate)
            else { return }
            appState.currentDate = moved
        }
        // Navigation (‹ ›, Today, go-to-date) changed the year: scroll to it.
        // A scroll-driven change lands here with shownYear already matching.
        .onChange(of: currentYear) {
            guard shownYear != currentYear else { return }
            withAnimation(.linear(duration: 0.25)) { topWeek = firstWeek(ofYear: currentYear) }
        }
    }

    private var currentYear: Int { appState.calendar.component(.year, from: appState.currentDate) }

    /// The year filling most of the viewport: the one 26 weeks below the top.
    private var shownYear: Int? {
        guard let top = topWeek,
              let mid = appState.calendar.date(byAdding: .day, value: 26 * 7, to: top) else { return nil }
        return appState.calendar.component(.year, from: mid)
    }

    private func firstWeek(ofYear year: Int) -> Date? {
        let cal = appState.calendar
        return cal.date(from: DateComponents(year: year, month: 1, day: 1)).map { cal.startOfWeek(for: $0) }
    }

    private func allWeeks(calendar: Calendar) -> [Date] {
        let thisYear = calendar.component(.year, from: Date())
        guard var day = firstWeek(ofYear: thisYear - 2),
              let end = calendar.date(from: DateComponents(year: thisYear + 4, month: 1, day: 1)) else { return [] }
        var result: [Date] = []
        while day < end {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 7, to: day) else { break }
            day = next
        }
        return result
    }
}

private struct YearWeekRow: View {
    @EnvironmentObject var store: CalendarStore
    @Environment(AppState.self) var appState
    let weekStart: Date
    let rowH: CGFloat
    let gutter: CGFloat

    var body: some View {
        let cal = appState.calendar
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        HStack(spacing: 0) {
            Text(monthLabel(calendar: cal))
                .font(CWT.mono(9))
                .foregroundStyle(CWT.inkSoft)
                .frame(width: gutter, alignment: .leading)
                .padding(.leading, 6)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        YearDayCell(day: day, rowH: rowH)
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
        .onAppear {
            // Rows of the neighboring years scroll in before currentDate
            // (and RootView's year fetch) follows.
            if let end = cal.date(byAdding: .day, value: 7, to: weekStart) {
                store.ensureFetched(DateInterval(start: weekStart, end: end))
            }
        }
    }

    /// Month name on the row containing the 1st of that month; the year
    /// number instead on January's row.
    private func monthLabel(calendar: Calendar) -> String {
        guard let day = calendar.firstOfMonth(inWeekStarting: weekStart) else { return "" }
        return calendar.component(.month, from: day) == 1
            ? String(calendar.component(.year, from: day)) : Fmt.month.string(from: day)
    }
}

private struct YearSpanChip: View {
    @Environment(AppState.self) var appState
    let event: CalEvent
    let showTitle: Bool

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        Group {
            if showTitle {
                Text(event.title ?? "Untitled")
                    .font(CWT.mono(7))
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
    @Environment(AppState.self) var appState
    let day: Date
    let rowH: CGFloat

    var body: some View {
        let cal = appState.calendar
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let evenMonth = cal.component(.month, from: day) % 2 == 0

        HStack(spacing: 3) {
            Text(Fmt.dayNum.string(from: day))
                .font(CWT.mono(9))
                .frame(width: 16, height: 13)
                .background { if isToday { Rectangle().fill(CWT.signalRed) } }
                .foregroundStyle(isToday ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(evenMonth ? CWT.monthBand : Color.clear)
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
