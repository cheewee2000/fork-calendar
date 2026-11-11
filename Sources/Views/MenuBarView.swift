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
        // Fires on :00 and :30 so "now" flips on the minute instead of up to 30s late.
        // ForkCalDebugClockOffset (seconds) shifts the menu bar's clock for scripted checks.
        let offset = UserDefaults.standard.double(forKey: "ForkCalDebugClockOffset")
        let first = Date(timeIntervalSinceReferenceDate: (Date.timeIntervalSinceReferenceDate / 30).rounded(.up) * 30)
        let t = Timer(fire: first, interval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date().addingTimeInterval(offset) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        now = Date().addingTimeInterval(offset)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject private var clock = MinuteClock.shared

    var body: some View {
        if let next = store.menuBarHeadline(now: clock.now), let start = next.startDate {
            let title = String((next.title ?? "").prefix(20))
            let mins = Int((start.timeIntervalSince(clock.now) / 60).rounded(.up))
            let label = mins <= 0 ? "now  \(title)" : "\(mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m")  \(title)"
            Image(nsImage: Self.render(label, highlighted: mins <= 0))
                .accessibilityLabel(label)
        } else {
            Image(systemName: "calendar")
        }
    }

    /// Status items ignore SwiftUI fonts and colors, so the label is pre-rendered in Space Mono:
    /// a template image normally (follows the menu bar's light/dark), and when it's time a
    /// black-on-signal-orange block that reads on either.
    static func render(_ string: String, highlighted: Bool) -> NSImage {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont(name: "SpaceMono-Regular", size: 12) ?? .menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.black,
        ])
        let textSize = text.size()
        let pad: CGFloat = highlighted ? 6 : 0
        let image = NSImage(size: NSSize(width: ceil(textSize.width) + pad * 2, height: 18), flipped: false) { rect in
            if highlighted {
                NSColor(CWT.signalOrange).setFill()
                rect.fill()
            }
            text.draw(at: NSPoint(x: pad, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = !highlighted
        return image
    }
}

struct MenuBarView: View {
    @EnvironmentObject var store: CalendarStore
    @Environment(AppState.self) var appState
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
                    .font(CWT.mono(12))
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
