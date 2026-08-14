import SwiftUI
import EventKit

struct MonthView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        let cal = appState.calendar
        let days = cal.monthGrid(for: appState.currentDate)
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
                let cellH = geo.size.height / 6
                let cellW = geo.size.width / 7
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                MonthCell(day: days[row * 7 + col])
                                    .frame(width: cellW, height: cellH)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MonthCell: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let day: Date

    var body: some View {
        let cal = appState.calendar
        let dayEvents = store.events(on: day, calendar: cal)
        let events = dayEvents.allDay + dayEvents.timed
        let isToday = day.isSameDay(as: Date(), calendar: cal)
        let inMonth = cal.isDate(day, equalTo: appState.currentDate, toGranularity: .month)

        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.dayNum.string(from: day))
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .frame(width: 20, height: 20)
                .background { if isToday { Circle().fill(Color.red) } }
                .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                .padding(.leading, 2)
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                MonthChip(event: event)
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
}

struct MonthChip: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    let event: EKEvent

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
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(isSelected ? 0.3 : event.isAllDay ? 0.16 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { appState.select(event) }
        .contextMenu {
            if event.calendar?.allowsContentModifications == true {
                Button("Duplicate") { store.duplicate(event) }
                Button("Delete", role: .destructive) { appState.requestDelete(event, store: store) }
            }
            Button("Copy title") { Clipboard.copy(event.title ?? "") }
        }
    }
}
