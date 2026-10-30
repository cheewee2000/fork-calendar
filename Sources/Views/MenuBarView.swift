#if os(macOS)
import SwiftUI
import AppKit

/// Ticks the menu bar views forward. TimelineView inside a MenuBarExtra label spins SwiftUI's
/// status-item update loop at launch, so the label observes this instead.
@MainActor
final class MinuteClock: ObservableObject {
    static let shared = MinuteClock()
    @Published private(set) var now = Date()
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject private var clock = MinuteClock.shared

    var body: some View {
        if let next = store.nextUpcomingEvent(now: clock.now), let start = next.startDate {
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
    @ObservedObject private var clock = MinuteClock.shared

    var body: some View {
        let now = clock.now
        let cal = Calendar.autoupdatingCurrent
        let upcoming = store.menuBarEvents(now: now, calendar: cal)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        VStack(alignment: .leading, spacing: 8) {
            agendaSection(title: "Today", events: upcoming.filter { $0.startDate < tomorrow })
            agendaSection(title: "Tomorrow", events: upcoming.filter { $0.endDate > tomorrow })
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
    private func agendaSection(title: String, events: [CalEvent]) -> some View {
        let all = events.filter(\.isAllDay) + events.filter { !$0.isAllDay }
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CWT.mono(10))
                .foregroundStyle(CWT.inkSoft)
            if all.isEmpty {
                Text("No events")
                    .font(CWT.mono(12))
                    .foregroundStyle(CWT.inkFaint)
            }
            ForEach(Array(all.prefix(6).enumerated()), id: \.offset) { _, event in
                HStack(spacing: 6) {
                    Circle()
                        .fill(event.calendar?.displayColor ?? .accentColor)
                        .frame(width: 6, height: 6)
                    Text(event.title ?? "Untitled")
                        .font(CWT.mono(12))
                        .lineLimit(1)
                    Spacer()
                    if !event.isAllDay, let s = event.startDate {
                        Text(Fmt.time.string(from: s))
                            .font(CWT.mono(10))
                            .foregroundStyle(CWT.inkSoft)
                    }
                    if let url = MeetLink.url(for: event) {
                        Button("Join") { openURL(url) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    }
                }
            }
        }
    }
}
#endif
