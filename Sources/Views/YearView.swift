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
        // ↑ / ↓: four week rows (about a month) per press.
        .onChange(of: appState.rowScrollTick) {
            guard appState.viewMode == .year, let top = topWeek,
                  let next = cal.date(byAdding: .day, value: 28 * appState.rowScrollDelta, to: top),
                  weeks.contains(next) else { return }
            withAnimation(.linear(duration: 0.12)) { topWeek = next }
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
            // The seven day cells are ONE canvas (month band, hairlines, day
            // number, today box) and one tap target, not seven view trees:
            // a year is ~370 cells, and building ~18 views for each was most
            // of the cost of switching to this view.
            GeometryReader { geo in
                let cellW = geo.size.width / 7
                let barH: CGFloat = rowH >= 26 ? 9 : 4
                let laneCap = rowH >= 38 ? 2 : 1
                let bars = SpanLayout.bars(days: days, store: store, calendar: cal)
                    .filter { $0.lane < laneCap }
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let today = Date()
                        for (i, day) in days.enumerated() {
                            let x = CGFloat(i) * cellW
                            if cal.component(.month, from: day) % 2 == 0 {
                                ctx.fill(Path(CGRect(x: x, y: 0, width: cellW, height: size.height)),
                                         with: .color(CWT.monthBand))
                            }
                            let isToday = day.isSameDay(as: today, calendar: cal)
                            let box = CGRect(x: x + 3, y: (size.height - 13) / 2, width: 16, height: 13)
                            if isToday { ctx.fill(Path(box), with: .color(CWT.signalRed)) }
                            ctx.draw(
                                Text(Fmt.dayNum.string(from: day))
                                    .font(CWT.mono(9))
                                    .foregroundStyle(isToday ? Color.white : Color.primary),
                                at: CGPoint(x: box.midX, y: box.midY))
                            ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)),
                                     with: .color(CWT.ruleSoft))
                        }
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 0.5)),
                                 with: .color(CWT.ruleSoft))
                    }
                    // All-day/multi-day events as compact bars along the row bottom
                    ForEach(bars) { bar in
                        YearSpanChip(event: bar.event, showTitle: barH >= 8)
                            .frame(width: CGFloat(bar.endIndex - bar.startIndex + 1) * cellW - 3, height: barH)
                            .offset(
                                x: CGFloat(bar.startIndex) * cellW + 1.5,
                                y: rowH - 1.5 - barH - CGFloat(bar.lane) * (barH + 1)
                            )
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    let i = min(max(Int(tap.location.x / max(cellW, 1)), 0), days.count - 1)
                    guard days.indices.contains(i) else { return }
                    appState.goTo(days[i])
                    appState.setViewMode(.day)
                })
            }
        }
        .frame(height: rowH)
        .onAppear {
            // Rows of the neighboring years scroll in before currentDate
            // (and RootView's year fetch) follows. Ask for the row's whole
            // year at once: per-week requests grew the fetch window a month
            // at a time — a store reload + cache save every few rows scrolled.
            if let end = cal.date(byAdding: .day, value: 7, to: weekStart),
               let from = cal.dateInterval(of: .year, for: weekStart)?.start,
               let to = cal.dateInterval(of: .year, for: end)?.end {
                store.ensureFetched(DateInterval(start: from, end: to))
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
