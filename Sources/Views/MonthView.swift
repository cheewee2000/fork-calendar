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
                        .font(CWT.mono(10, .semibold))
                        .foregroundStyle(CWT.inkSoft)
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
                MonthSpanBar(bar: bar, cellW: cellW, rowH: rowH, barsTop: barsTop)
            }
        }
        .onAppear {
            // Lazy rows fetch their own range: on tall windows many weeks are
            // visible beyond the header month's fetch window.
            if let end = cal.date(byAdding: .day, value: 7, to: weekStart) {
                store.ensureFetched(DateInterval(start: weekStart, end: end))
            }
        }
    }
}

/// A span bar in the month grid: drag to move (horizontal = days, vertical =
/// weeks), drag an edge to extend into a multi-day span.
struct MonthSpanBar: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let bar: SpanBar
    let cellW: CGFloat
    let rowH: CGFloat
    let barsTop: CGFloat

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var moveTranslation: CGSize = .zero
    @State private var resizeCols = 0
    @State private var resizingLead = false
    @State private var isResizing = false

    private var isEditable: Bool {
        bar.event.calendar?.allowsContentModifications == true
    }

    var body: some View {
        var startIdx = bar.startIndex
        var endIdx = bar.endIndex
        if isResizing {
            if resizingLead {
                startIdx = min(startIdx + resizeCols, endIdx)
            } else {
                endIdx = max(endIdx + resizeCols, startIdx)
            }
        }

        return SpanBarView(event: bar.event, duplicates: bar.duplicates, compact: true)
            .frame(width: CGFloat(endIdx - startIdx + 1) * cellW - 6, height: 14)
            #if os(macOS)
            .overlay(alignment: .leading) { if isEditable { resizeHandle(lead: true) } }
            .overlay(alignment: .trailing) { if isEditable { resizeHandle(lead: false) } }
            #endif
            .opacity(isDragging || isResizing ? 0.75 : 1)
            .zIndex(isDragging ? 100 : 0)
            #if os(iOS)
            .overlay {
                LongPressDrag(
                    onTap: { _ in appState.select(bar.event) },
                    onBegan: { _ in
                        guard isEditable else { return }
                        isDragging = true
                        moveTranslation = .zero
                    },
                    onMoved: { _, translation in
                        guard isEditable else { return }
                        moveTranslation = translation
                        dragOffset = snappedOffset(translation)
                    },
                    onEnded: { completed in
                        let translation = moveTranslation
                        isDragging = false
                        dragOffset = .zero
                        moveTranslation = .zero
                        guard completed, isEditable else { return }
                        shift(byDays: moveDelta(translation))
                    }
                )
            }
            #endif
            .offset(
                x: CGFloat(startIdx) * cellW + 3 + dragOffset.width,
                y: barsTop + CGFloat(bar.lane) * 16 + dragOffset.height
            )
            #if os(macOS)
            .gesture(moveDrag)
            #endif
    }

    private func snappedOffset(_ translation: CGSize) -> CGSize {
        CGSize(
            width: (translation.width / cellW).rounded() * cellW,
            height: (translation.height / rowH).rounded() * rowH
        )
    }

    private func moveDelta(_ translation: CGSize) -> Int {
        Int((translation.width / cellW).rounded()) + 7 * Int((translation.height / rowH).rounded())
    }


    private func shift(byDays delta: Int) {
        guard delta != 0 else { return }
        let cal = appState.calendar
        let snapshot = EventSnapshot(bar.event)
        bar.event.startDate = cal.date(byAdding: .day, value: delta, to: bar.event.startDate) ?? bar.event.startDate
        bar.event.endDate = cal.date(byAdding: .day, value: delta, to: bar.event.endDate) ?? bar.event.endDate
        appState.commitChange(to: bar.event, snapshot: snapshot, isNew: false, store: store)
    }

    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard isEditable else { return }
                isDragging = true
                dragOffset = snappedOffset(value.translation)
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard isEditable else { return }
                shift(byDays: moveDelta(value.translation))
            }
    }

    private func resizeHandle(lead: Bool) -> some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isResizing = true
                        resizingLead = lead
                        resizeCols = Int((value.translation.width / cellW).rounded())
                    }
                    .onEnded { value in
                        defer {
                            isResizing = false
                            resizeCols = 0
                        }
                        let delta = Int((value.translation.width / cellW).rounded())
                            + 7 * Int((value.translation.height / rowH).rounded())
                        guard delta != 0 else { return }
                        let cal = appState.calendar
                        let snapshot = EventSnapshot(bar.event)
                        if lead {
                            guard let newStart = cal.date(byAdding: .day, value: delta, to: bar.event.startDate),
                                  newStart < bar.event.endDate else { return }
                            bar.event.startDate = newStart
                        } else {
                            guard let newEnd = cal.date(byAdding: .day, value: delta, to: bar.event.endDate),
                                  newEnd > bar.event.startDate else { return }
                            bar.event.endDate = newEnd
                        }
                        appState.commitChange(to: bar.event, snapshot: snapshot, isNew: false, store: store)
                    }
            )
    }
}

struct MonthCell: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    let day: Date
    let cellW: CGFloat
    let rowH: CGFloat
    var laneInset: CGFloat = 0

    /// Highlighted while drag-creating an all-day span, or covered by a
    /// drag-created event still open (unsaved) in the details panel.
    private var isInDraftRange: Bool {
        let cal = appState.calendar
        let key = cal.startOfDay(for: day)
        if let range = appState.monthDragRange { return range.contains(key) }
        if let ctx = appState.panelContext, ctx.isNew, ctx.event.isAllDay,
           let s = ctx.event.startDate, let e = ctx.event.endDate {
            let startDay = cal.startOfDay(for: s)
            let lastDay = cal.startOfDay(for: max(e.addingTimeInterval(-1), s))
            return key >= startDay && key <= lastDay
        }
        return false
    }

    var body: some View {
        let cal = appState.calendar
        let events = EventLayout.mergeDuplicates(
            settings.monthAllDayOnly ? [] : store.events(on: day, calendar: cal).timed
        )
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let dayOfMonth = cal.component(.day, from: day)
        let month = cal.component(.month, from: day)
        let evenMonth = month % 2 == 0
        let isWeekend = cal.isDateInWeekend(day)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(dayOfMonth == 1 ? monthDayLabel : Fmt.dayNum.string(from: day))
                    .font(CWT.mono(11, isToday || dayOfMonth == 1 ? .bold : .regular))
                    .padding(.horizontal, isToday ? 5 : 0)
                    .frame(height: 20)
                    .background { if isToday { Rectangle().fill(CWT.signalRed) } }
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 3)
            if laneInset > 0 {
                Color.clear.frame(height: laneInset)
            }
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, pair in
                MonthChip(event: pair.primary, duplicates: pair.duplicates, cellW: cellW, rowH: rowH)
            }
            if events.count > 3 {
                Text("\(events.count - 3) more")
                    .font(CWT.mono(9))
                    .foregroundStyle(CWT.inkSoft)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            (evenMonth ? CWT.paper2 : Color.clear)
                .overlay(isWeekend ? CWT.paper3.opacity(0.55) : Color.clear)
                .overlay(isInDraftRange ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(CWT.rule).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(CWT.ruleSoft).frame(width: 1)
        }
        .contentShape(Rectangle())
        #if os(iOS)
        // Background layer so chips' own touch layers stay above it.
        .background {
            LongPressDrag(
                onTap: { _ in
                    if appState.panelContext != nil {
                        appState.closePanel()
                    } else {
                        appState.currentDate = day
                    }
                },
                onBegan: { _ in
                    updateDragRange(translation: .zero)
                },
                onMoved: { _, translation in
                    updateDragRange(translation: translation)
                },
                onEnded: { completed in
                    if completed {
                        finishDragCreate()
                    } else {
                        appState.monthDragRange = nil
                    }
                }
            )
        }
        #else
        .onTapGesture(count: 2) {
            appState.currentDate = day
            appState.viewMode = .day
        }
        .onTapGesture { appState.currentDate = day }
        .gesture(createDrag)
        #endif
    }

    private func updateDragRange(translation: CGSize) {
        let cal = appState.calendar
        let delta = Int((translation.width / cellW).rounded())
            + 7 * Int((translation.height / rowH).rounded())
        let anchor = cal.startOfDay(for: day)
        let target = cal.date(byAdding: .day, value: delta, to: anchor) ?? anchor
        appState.monthDragRange = min(anchor, target)...max(anchor, target)
    }

    private func finishDragCreate() {
        if let range = appState.monthDragRange {
            let cal = appState.calendar
            let end = cal.date(byAdding: .day, value: 1, to: range.upperBound) ?? range.upperBound
            appState.newEvent(store: store, start: range.lowerBound, end: end, allDay: true)
        }
        appState.monthDragRange = nil
    }

    /// Drag across cells to create a (multi-day) all-day event — horizontal =
    /// days, vertical = weeks, mirroring how chips move.
    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                updateDragRange(translation: value.translation)
            }
            .onEnded { _ in
                finishDragCreate()
            }
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
    /// Identical copies on other calendars, merged into this chip.
    var duplicates: [EKEvent] = []
    var cellW: CGFloat = 120
    var rowH: CGFloat = 108

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var moveTranslation: CGSize = .zero

    private var isEditable: Bool {
        event.calendar?.allowsContentModifications == true
    }

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == eventKey(event)
        HStack(spacing: 4) {
            if duplicates.isEmpty {
                Circle().fill(color).frame(width: 5, height: 5)
            } else {
                // One strip per calendar this event lives on (merged copies).
                HStack(spacing: 1) {
                    ForEach(Array(([event] + duplicates).enumerated()), id: \.offset) { _, copy in
                        Rectangle()
                            .fill(copy.calendar?.displayColor ?? Color.accentColor)
                            .frame(width: 3)
                    }
                }
                .frame(height: 11)
            }
            if !event.isAllDay, let s = event.startDate {
                Text(Fmt.time.string(from: s))
                    .font(CWT.mono(9))
                    .foregroundStyle(CWT.inkSoft)
            }
            Text(event.title ?? "Untitled")
                .font(CWT.mono(9, .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Rectangle().fill(
            isDragging ? color.opacity(0.35) : color.opacity(isSelected ? 0.3 : event.isAllDay ? 0.16 : 0)
        ))
        .overlay {
            if store.awaitingResponse(event) {
                Rectangle()
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .contentShape(Rectangle())
        .offset(dragOffset)
        .zIndex(isDragging ? 100 : 0)
        .opacity(isDragging ? 0.85 : 1)
        #if os(iOS)
        .overlay {
            LongPressDrag(
                onTap: { _ in appState.select(event) },
                onBegan: { _ in
                    guard isEditable else { return }
                    isDragging = true
                    moveTranslation = .zero
                },
                onMoved: { _, translation in
                    guard isEditable else { return }
                    moveTranslation = translation
                    dragOffset = translation
                },
                onEnded: { completed in
                    let translation = moveTranslation
                    isDragging = false
                    dragOffset = .zero
                    moveTranslation = .zero
                    guard completed, isEditable else { return }
                    commitMove(translation)
                }
            )
        }
        #endif
        .onTapGesture { appState.select(event) }
        #if os(macOS)
        .gesture(moveDrag)
        .contextMenu {
            if isEditable {
                Button("Duplicate") { store.duplicate(event) }
                Button("Delete", role: .destructive) { appState.requestDelete(event, store: store) }
            }
            Button("Copy title") { Clipboard.copy(event.title ?? "") }
        }
        #endif
    }

    private func commitMove(_ translation: CGSize) {
        let dayDelta = Int((translation.width / cellW).rounded())
            + 7 * Int((translation.height / rowH).rounded())
        guard dayDelta != 0 else { return }
        let snapshot = EventSnapshot(event)
        let cal = appState.calendar
        event.startDate = cal.date(byAdding: .day, value: dayDelta, to: event.startDate) ?? event.startDate
        event.endDate = cal.date(byAdding: .day, value: dayDelta, to: event.endDate) ?? event.endDate
        appState.commitChange(to: event, snapshot: snapshot, isNew: false, store: store)
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
                commitMove(value.translation)
            }
    }

    #if os(iOS)
    private var moveLongPress: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard isEditable, case .second(true, let drag) = value else { return }
                if !isDragging {
                    isDragging = true
                    Haptics.tap()
                }
                if let drag { dragOffset = drag.translation }
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard isEditable, case .second(true, let drag?) = value else { return }
                commitMove(drag.translation)
            }
    }
    #endif
}
