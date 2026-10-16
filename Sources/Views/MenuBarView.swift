#if os(macOS)
import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        if let next = store.nextUpcomingEvent, let start = next.startDate {
            Text("\(Fmt.time.string(from: start))  \(String((next.title ?? "").prefix(20)))")
        } else {
            Image(systemName: "calendar")
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        let cal = Calendar.autoupdatingCurrent
        let today = Date()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
        VStack(alignment: .leading, spacing: 8) {
            agendaSection(title: "Today", day: today, calendar: cal)
            agendaSection(title: "Tomorrow", day: tomorrow, calendar: cal)
            Divider()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("Open Fork Calendar", systemImage: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func agendaSection(title: String, day: Date, calendar: Calendar) -> some View {
        let dayEvents = store.events(on: day, calendar: calendar)
        let all = dayEvents.allDay + dayEvents.timed
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CWT.ui(11))
                .foregroundStyle(CWT.inkSoft)
            if all.isEmpty {
                Text("No events")
                    .font(CWT.ui(12))
                    .foregroundStyle(CWT.inkFaint)
            }
            ForEach(Array(all.prefix(6).enumerated()), id: \.offset) { _, event in
                HStack(spacing: 6) {
                    Circle()
                        .fill(event.calendar?.displayColor ?? .accentColor)
                        .frame(width: 6, height: 6)
                    Text(event.title ?? "Untitled")
                        .font(CWT.ui(12))
                        .lineLimit(1)
                    Spacer()
                    if !event.isAllDay, let s = event.startDate {
                        Text(Fmt.time.string(from: s))
                            .font(CWT.ui(11))
                            .foregroundStyle(CWT.inkSoft)
                    }
                    if let url = MeetLink.url(for: event) {
                        Button("Join") { openURL(url) }
                            .buttonStyle(.cwt(on: true, size: 11))
                    }
                }
            }
        }
    }
}
#endif
