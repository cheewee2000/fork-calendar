import SwiftUI
import EventKit

/// Day/week timeline: hour gutter, day columns, drag-to-create, drag-to-move.
struct TimeGridView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let days: [Date]

    private let gutterWidth: CGFloat = 54
    private let hourHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            dayHeaders
            allDayRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    grid
                }
                .onAppear {
                    proxy.scrollTo("hour-8", anchor: .top)
                }
            }
        }
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = day.isSameDay(as: Date(), calendar: appState.calendar)
                VStack(spacing: 2) {
                    Text(Fmt.weekdayShort.string(from: day).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isToday ? Color.red : Color.secondary)
                    Text(Fmt.dayNum.string(from: day))
                        .font(.system(size: 15, weight: isToday ? .bold : .regular))
                        .frame(width: 26, height: 26)
                        .background { if isToday { Circle().fill(Color.red) } }
                        .foregroundStyle(isToday ? Color.white : Color.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.currentDate = day
                    appState.viewMode = .day
                }
            }
        }
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: gutterWidth)
            ForEach(days, id: \.self) { day in
                let allDay = store.events(on: day, calendar: appState.calendar).allDay
                VStack(spacing: 2) {
                    ForEach(Array(allDay.prefix(3).enumerated()), id: \.offset) { _, event in
                        AllDayChip(event: event)
                    }
                    if allDay.count > 3 {
                        Text("+\(allDay.count - 3) more")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 2)
            }
        }
        .padding(.bottom, 4)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            timeGutter
            GeometryReader { geo in
                let colWidth = geo.size.width / CGFloat(days.count)
                ZStack(alignment: .topLeading) {
                    hourLines
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            DayColumn(day: day, colWidth: colWidth, hourHeight: hourHeight)
                        }
                    }
                }
            }
            .frame(height: hourHeight * 24)
        }
        .padding(.bottom, 20)
    }

    private var timeGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Group {
                    if hour > 0 {
                        Text(hourLabel(hour))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 8)
                            .offset(y: -6)
                    }
                }
                .frame(width: gutterWidth, height: hourHeight, alignment: .topTrailing)
                .id("hour-\(hour)")
            }
        }
        .frame(width: gutterWidth)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Color.clear
                    .frame(height: hourHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return Fmt.hour.string(from: date)
    }
}

struct DayColumn: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let day: Date
    let colWidth: CGFloat
    let hourHeight: CGFloat

    @State private var draftStart: CGFloat?
    @State private var draftEnd: CGFloat?

    var body: some View {
        let timed = store.events(on: day, calendar: appState.calendar).timed
        let positioned = EventLayout.layout(timed)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(createDrag)
                .gesture(SpatialTapGesture().onEnded { value in
                    createEvent(fromY: snap(value.location.y), toY: snap(value.location.y) + hourHeight)
                })

            if let s = draftStart, let e = draftEnd {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.6)))
                    .frame(width: colWidth - 6, height: max(abs(e - s), 10))
                    .offset(x: 2, y: min(s, e))
                    .allowsHitTesting(false)
            }

            ForEach(positioned) { item in
                EventBlockView(item: item, day: day, colWidth: colWidth, hourHeight: hourHeight)
            }

            if day.isSameDay(as: Date(), calendar: appState.calendar) {
                NowLine(hourHeight: hourHeight)
            }
        }
        .frame(width: colWidth, height: hourHeight * 24)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
    }

    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if draftStart == nil { draftStart = snap(value.startLocation.y) }
                draftEnd = snap(value.location.y)
            }
            .onEnded { _ in
                if let s = draftStart, let e = draftEnd, abs(e - s) >= hourHeight / 8 {
                    createEvent(fromY: min(s, e), toY: max(s, e))
                }
                draftStart = nil
                draftEnd = nil
            }
    }

    private func snap(_ y: CGFloat) -> CGFloat {
        let quarter = hourHeight / 4
        return (y / quarter).rounded() * quarter
    }

    private func date(atY y: CGFloat) -> Date {
        let clamped = max(0, min(y, hourHeight * 24))
        let hours = Double(clamped / hourHeight)
        return appState.calendar.startOfDay(for: day).addingTimeInterval(hours * 3600)
    }

    private func createEvent(fromY: CGFloat, toY: CGFloat) {
        let start = date(atY: fromY)
        var end = date(atY: toY)
        if end <= start { end = start.addingTimeInterval(1800) }
        appState.newEvent(store: store, start: start, end: end)
    }
}

struct NowLine: View {
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let start = Calendar.autoupdatingCurrent.startOfDay(for: context.date)
            let y = CGFloat(context.date.timeIntervalSince(start) / 3600) * hourHeight
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Rectangle().fill(Color.red).frame(height: 1.5)
            }
            .offset(y: y - 3.5)
        }
        .allowsHitTesting(false)
    }
}

struct EventBlockView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let item: PositionedEvent
    let day: Date
    let colWidth: CGFloat
    let hourHeight: CGFloat

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        let cal = appState.calendar
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let start = max(item.event.startDate ?? dayStart, dayStart)
        let end = min(item.event.endDate ?? dayEnd, dayEnd)
        let y = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
        let height = max(CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight, 16)
        let subWidth = (colWidth - 6) / CGFloat(item.columnCount)
        let x = 2 + subWidth * CGFloat(item.column)
        let color = item.event.calendar?.displayColor ?? Color.accentColor

        VStack(alignment: .leading, spacing: 1) {
            Text(item.event.title ?? "Untitled")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(height > 32 ? 2 : 1)
            if height > 34, let s = item.event.startDate {
                Text(Fmt.time.string(from: s))
                    .font(.system(size: 9))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(color)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(width: max(subWidth - 2, 12), height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(isDragging ? 0.7 : 1)
        .offset(x: x + dragOffset.width, y: y + dragOffset.height)
        .onTapGesture { appState.edit(item.event) }
        .gesture(moveDrag)
    }

    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard item.event.calendar?.allowsContentModifications == true else { return }
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard item.event.calendar?.allowsContentModifications == true else { return }
                let minuteDelta = (Double(value.translation.height / hourHeight) * 60 / 15).rounded() * 15
                let dayDelta = (value.translation.width / colWidth).rounded()
                guard minuteDelta != 0 || dayDelta != 0 else { return }
                let interval = minuteDelta * 60 + Double(dayDelta) * 86400
                item.event.startDate = item.event.startDate.addingTimeInterval(interval)
                item.event.endDate = item.event.endDate.addingTimeInterval(interval)
                store.save(item.event)
            }
    }
}

struct AllDayChip: View {
    @EnvironmentObject var appState: AppState
    let event: EKEvent

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        Text(event.title ?? "Untitled")
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.16)))
            .contentShape(Rectangle())
            .onTapGesture { appState.edit(event) }
    }
}
