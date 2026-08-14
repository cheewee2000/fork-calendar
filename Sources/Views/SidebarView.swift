import SwiftUI
import EventKit

struct SidebarView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section {
                MiniMonthView()
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
                    .listRowSeparator(.hidden)
            }
            ForEach(store.calendarsBySource, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                        CalendarRow(cal: cal)
                    }
                }
            }
        }
        .navigationTitle("Fork Calendar")
        .safeAreaInset(edge: .bottom) {
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }
}

struct CalendarRow: View {
    @EnvironmentObject var store: CalendarStore
    let cal: EKCalendar

    var body: some View {
        Button {
            store.toggle(cal)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(cal.displayColor.opacity(store.isVisible(cal) ? 1 : 0.25))
                    .frame(width: 14, height: 14)
                    .overlay {
                        if store.isVisible(cal) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(cal.title)
                    .foregroundStyle(store.isVisible(cal) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MiniMonthView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let cal = appState.calendar
        VStack(spacing: 6) {
            HStack {
                Text(Fmt.monthYear.string(from: appState.currentDate))
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: -1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.left").font(.caption2)
                }
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: 1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cal.monthGrid(for: appState.currentDate).enumerated()), id: \.offset) { _, day in
                    let isToday = day.isSameDay(as: Date(), calendar: cal)
                    let isSelected = day.isSameDay(as: appState.currentDate, calendar: cal)
                    let inMonth = cal.isDate(day, equalTo: appState.currentDate, toGranularity: .month)
                    Text(Fmt.dayNum.string(from: day))
                        .font(.system(size: 10, weight: isToday ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .foregroundStyle(isToday ? Color.red : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                        .contentShape(Rectangle())
                        .onTapGesture { appState.currentDate = day }
                }
            }
        }
    }
}
