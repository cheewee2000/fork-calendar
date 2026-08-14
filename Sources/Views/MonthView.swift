import SwiftUI
import EventKit

private struct WeekPosition: Equatable {
    let week: Date
    let y: CGFloat
}

private struct WeekPositionKey: PreferenceKey {
    static var defaultValue: [WeekPosition] = []
    static func reduce(value: inout [WeekPosition], nextValue: () -> [WeekPosition]) {
        value.append(contentsOf: nextValue())
    }
}

/// Continuous vertically-scrolling month view (a stack of week rows spanning
/// ±1–2 years). The header month updates as you scroll; navigation scrolls here.
struct MonthView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    private let rowHeight: CGFloat = 108

    private var weeks: [Date] {
        let cal = appState.calendar
        let today = Date()
        guard let windowStart = cal.date(byAdding: .month, value: -12, to: today),
              let windowEnd = cal.date(byAdding: .month, value: 24, to: today) else { return [] }
        var result: [Date] = []
        var day = cal.startOfWeek(for: windowStart)
        while day < windowEnd {
            result.append(day)
            guard let next = cal.date(byAdding: .day, value: 7, to: day) else { break }
            day = next
        }
        return result
    }

    var body: some View {
        let cal = appState.calendar
        let allWeeks = weeks
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            GeometryReader { geo in
                let cellW = geo.size.width / 7
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(allWeeks, id: \.self) { weekStart in
                                MonthWeekRow(weekStart: weekStart, cellW: cellW, rowH: rowHeight)
                                    .frame(height: rowHeight)
                                    .id(weekStart)
                                    .background(
                                        GeometryReader { g in
                                            Color.clear.preference(
                                                key: WeekPositionKey.self,
                                                value: [WeekPosition(week: weekStart, y: g.frame(in: .named("monthScroll")).minY)]
                                            )
                                        }
                                    )
                            }
                        }
                    }
                    .coordinateSpace(name: "monthScroll")
                    .onPreferenceChange(WeekPositionKey.self) { positions in
                        updateCurrentMonth(from: positions)
                    }
                    .onAppear {
                        let target = appState.monthScrollTarget ?? appState.currentDate
                        proxy.scrollTo(cal.startOfWeek(for: target), anchor: .top)
                        appState.monthScrollTarget = nil
                    }
                    .onChange(of: appState.monthScrollTarget) {
                        guard let target = appState.monthScrollTarget else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(cal.startOfWeek(for: target), anchor: .top)
                        }
                        appState.monthScrollTarget = nil
                    }
                }
            }
        }
    }

    /// The topmost visible week defines the header month while scrolling.
    private func updateCurrentMonth(from positions: [WeekPosition]) {
        guard appState.viewMode == .month else { return }
        guard let top = positions
            .filter({ $0.y > -rowHeight * 0.6 })
            .min(by: { $0.y < $1.y })
        else { return }
        let cal = appState.calendar
        guard let representative = cal.date(byAdding: .day, value: 3, to: top.week) else { return }
        if !cal.isDate(representative, equalTo: appState.currentDate, toGranularity: .month) {
            appState.currentDate = representative
        }
    }
}

struct MonthWeekRow: View {
    let weekStart: Date
    let cellW: CGFloat
    let rowH: CGFloat
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore

    var body: some View {
        let cal = appState.calendar
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let bars = SpanLayout.bars(days: days, store: store, calendar: cal).filter { $0.lane < 3 }
        let laneCount = (bars.map(\.lane).max() ?? -1) + 1
        let barsTop: CGFloat = 24
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    MonthCell(day: day, cellW: cellW, rowH: rowH, laneInset: CGFloat(laneCount) * 16)
                        .frame(width: cellW, height: rowH)
                }
            }
            ForEach(bars) { bar in
                SpanBarView(event: bar.event, compact: true)
                    .frame(
                        width: CGFloat(bar.endIndex - bar.startIndex + 1) * cellW - 6,
                        height: 14
                    )
                    .offset(x: CGFloat(bar.startIndex) * cellW + 3, y: barsTop + CGFloat(bar.lane) * 16)
            }
        }
    }
}

struct MonthCell: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let day: Date
    let cellW: CGFloat
    let rowH: CGFloat
    var laneInset: CGFloat = 0

    var body: some View {
        let cal = appState.calendar
        let events = store.events(on: day, calendar: cal).timed
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let dayOfMonth = cal.component(.day, from: day)
        let month = cal.component(.month, from: day)
        let evenMonth = month % 2 == 0

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(dayOfMonth == 1 ? monthDayLabel : Fmt.dayNum.string(from: day))
                    .font(.system(size: 11, weight: isToday || dayOfMonth == 1 ? .bold : .regular))
                    .padding(.horizontal, isToday ? 5 : 0)
                    .frame(height: 20)
                    .background { if isToday { Capsule().fill(Color.red) } }
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 3)
            if laneInset > 0 {
                Color.clear.frame(height: laneInset)
            }
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                MonthChip(event: event, cellW: cellW, rowH: rowH)
            }
            if events.count > 3 {
                Text("\(events.count - 3) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(evenMonth ? Color.primary.opacity(0.03) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            appState.currentDate = day
            appState.viewMode = .day
        }
        .onTapGesture { appState.currentDate = day }
    }

    private var monthDayLabel: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: day)
    }
}

struct MonthChip: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    let event: EKEvent
    var cellW: CGFloat = 120
    var rowH: CGFloat = 108

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private var isEditable: Bool {
        event.calendar?.allowsContentModifications == true
    }

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == eventKey(event)
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            if !event.isAllDay, let s = event.startDate {
                Text(Fmt.time.string(from: s))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(event.title ?? "Untitled")
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(
            isDragging ? color.opacity(0.35) : color.opacity(isSelected ? 0.3 : event.isAllDay ? 0.16 : 0)
        ))
        .overlay {
            if event.needsMyResponse {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .contentShape(Rectangle())
        .offset(dragOffset)
        .zIndex(isDragging ? 100 : 0)
        .opacity(isDragging ? 0.85 : 1)
        .onTapGesture { appState.select(event) }
        .gesture(moveDrag)
        .contextMenu {
            if isEditable {
                Button("Duplicate") { store.duplicate(event) }
                Button("Delete", role: .destructive) { appState.requestDelete(event, store: store) }
            }
            Button("Copy title") { Clipboard.copy(event.title ?? "") }
        }
    }

    /// Drag a chip to another day cell — horizontal = days, vertical = weeks.
    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard isEditable else { return }
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard isEditable else { return }
                let dayDelta = Int((value.translation.width / cellW).rounded())
                    + 7 * Int((value.translation.height / rowH).rounded())
                guard dayDelta != 0 else { return }
                let snapshot = EventSnapshot(event)
                let cal = appState.calendar
                event.startDate = cal.date(byAdding: .day, value: dayDelta, to: event.startDate) ?? event.startDate
                event.endDate = cal.date(byAdding: .day, value: dayDelta, to: event.endDate) ?? event.endDate
                appState.commitChange(to: event, snapshot: snapshot, isNew: false, store: store)
            }
    }
}
