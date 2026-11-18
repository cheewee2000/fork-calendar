import WidgetKit
import SwiftUI

// MARK: - Model

struct UpNextEntry: TimelineEntry {
    let date: Date
    let hasAccess: Bool
    /// Today + tomorrow, sorted by start (stable tiebreak on id).
    let events: [WidgetEvent]

    static let sample = UpNextEntry(
        date: .now, hasAccess: true,
        events: [
            WidgetEvent(id: "1", title: "Studio standup", start: .now.addingTimeInterval(1800),
                        end: .now.addingTimeInterval(5400), isAllDay: false, color: Color(hex: "7D6378")!),
            WidgetEvent(id: "2", title: "Anodizing pickup", start: .now.addingTimeInterval(9000),
                        end: .now.addingTimeInterval(12600), isAllDay: false, color: Color(hex: "2E7D4F")!),
            WidgetEvent(id: "3", title: "Pen Type-B run", start: .now.addingTimeInterval(16200),
                        end: .now.addingTimeInterval(19800), isAllDay: false, color: Color(hex: "D11D1D")!),
        ]
    )
}

// MARK: - Provider

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(context.isPreview ? .sample : load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date()
        let current = load(at: now)
        guard current.hasAccess else {
            completion(Timeline(entries: [current], policy: .after(now.addingTimeInterval(1800))))
            return
        }
        // Re-render every quarter hour (the now-line and the grid's first hour move) and at
        // every event boundary until midnight, then start over.
        let cal = Calendar.autoupdatingCurrent
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(86400)
        var dates: Set<Date> = [now, midnight]
        var tick = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 900).rounded(.down) * 900 + 900)
        while tick < midnight { dates.insert(tick); tick += 900 }
        for e in current.events where !e.isAllDay {
            if e.start > now, e.start < midnight { dates.insert(e.start) }
            if e.end > now, e.end < midnight { dates.insert(e.end) }
        }
        let entries = dates.sorted().map {
            UpNextEntry(date: $0, hasAccess: true, events: current.events)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// Reads the snapshot the app publishes (today + 2 days, already filtered).
    private func load(at date: Date) -> UpNextEntry {
        guard let items = WidgetData.read() else {
            return UpNextEntry(date: date, hasAccess: false, events: [])
        }
        let cal = Calendar.autoupdatingCurrent
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(172800)

        var seen = Set<String>()
        var events: [WidgetEvent] = []
        for e in items where e.start < end && e.end > start {
            // Same event mirrored across calendars collapses to one row.
            let key = "\(e.title)|\(e.start.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { continue }
            events.append(WidgetEvent(
                id: e.id + String(e.start.timeIntervalSince1970),
                title: e.title, start: e.start, end: e.end,
                isAllDay: e.isAllDay || e.end.timeIntervalSince(e.start) >= 86400,
                color: Color(hex: e.colorHex) ?? Color(hex: "7D6378")!
            ))
        }
        return UpNextEntry(date: date, hasAccess: true, events: events)
    }
}

// MARK: - Row slicing

struct DaySlice {
    var today: [WidgetEvent] = []      // all-day first, then timed still ongoing/upcoming
    var tomorrow: [WidgetEvent] = []

    init(_ entry: UpNextEntry) {
        let cal = Calendar.autoupdatingCurrent
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: entry.date))
            ?? entry.date.addingTimeInterval(86400)
        var todayAllDay: [WidgetEvent] = []
        var todayTimed: [WidgetEvent] = []
        for e in entry.events {
            if e.start >= midnight {
                if !e.isAllDay { tomorrow.append(e) }
            } else if e.isAllDay {
                if e.end > entry.date { todayAllDay.append(e) }
            } else if e.end > entry.date {
                todayTimed.append(e)
            }
        }
        today = todayAllDay + todayTimed
    }
}

// MARK: - Views


struct SmallView: View {
    let entry: UpNextEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.weekdayShort.string(from: entry.date).uppercased())
                    .font(CWT.mono(11))
                    .foregroundStyle(CWT.inkFaint)
                Spacer()
                Text(Fmt.dayNum.string(from: entry.date))
                    .font(CWT.mono(18))
                    .foregroundStyle(CWT.ink)
            }
            Rectangle().fill(CWT.rule).frame(height: 1)
            TimeGrid(events: entry.events, now: entry.date)
        }
    }
}

struct MediumView: View {
    let entry: UpNextEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.weekdayShort.string(from: entry.date).uppercased())
                    .font(CWT.mono(11))
                    .foregroundStyle(CWT.inkFaint)
                Text(Fmt.dayNum.string(from: entry.date))
                    .font(CWT.mono(30))
                    .foregroundStyle(CWT.ink)
                Text(Fmt.month.string(from: entry.date).uppercased())
                    .font(CWT.mono(11))
                    .foregroundStyle(CWT.inkFaint)
                Spacer(minLength: 0)
            }
            Rectangle().fill(CWT.rule).frame(width: 1)
            TimeGrid(events: entry.events, now: entry.date)
        }
    }
}

struct LargeView: View {
    let entry: UpNextEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.weekdayShort.string(from: entry.date).uppercased())
                    .font(CWT.mono(12))
                    .foregroundStyle(CWT.inkFaint)
                Spacer()
                Text("\(Fmt.month.string(from: entry.date).uppercased()) \(Fmt.dayNum.string(from: entry.date))")
                    .font(CWT.mono(12))
                    .foregroundStyle(CWT.ink)
            }
            Rectangle().fill(CWT.rule).frame(height: 1)
            TimeGrid(events: entry.events, now: entry.date)
        }
    }
}

struct RectangularView: View {
    let entry: UpNextEntry
    var body: some View {
        let slice = DaySlice(entry)
        let next = slice.today.first(where: { !$0.isAllDay }) ?? slice.tomorrow.first
        VStack(alignment: .leading, spacing: 1) {
            if let next {
                Text(next.title)
                    .font(CWT.mono(13))
                    .lineLimit(1)
                Text(next.start.isTomorrow(from: entry.date)
                     ? "TMRW \(WFmt.compact(next.start))"
                     : "\(WFmt.compact(next.start))–\(WFmt.compact(next.end))")
                    .font(CWT.mono(12))
            } else {
                Text("NO EVENTS").font(CWT.mono(12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineView: View {
    let entry: UpNextEntry
    var body: some View {
        let slice = DaySlice(entry)
        let next = slice.today.first(where: { !$0.isAllDay }) ?? slice.tomorrow.first
        if let next {
            Text("\(WFmt.compact(next.start)) \(next.title)")
        } else {
            Text("No events")
        }
    }
}

private extension Date {
    func isTomorrow(from reference: Date) -> Bool {
        !Calendar.autoupdatingCurrent.isDate(self, inSameDayAs: reference)
    }
}

struct AccessView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("FORK CALENDAR")
                .font(CWT.mono(10))
                .foregroundStyle(CWT.ink)
            Text("Open the app to sign in to Google")
                .font(CWT.mono(10))
                .foregroundStyle(CWT.inkFaint)
                .multilineTextAlignment(.center)
        }
    }
}

struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        Group {
            if !entry.hasAccess {
                AccessView()
            } else {
                switch family {
                case .systemSmall: SmallView(entry: entry)
                // Extra large (iPad only) is the medium layout with room for more hours.
                case .systemMedium, .systemExtraLarge: MediumView(entry: entry)
                case .accessoryRectangular: RectangularView(entry: entry)
                case .accessoryInline: InlineView(entry: entry)
                default: LargeView(entry: entry)
                }
            }
        }
        .containerBackground(CWT.paper, for: .widget)
    }
}

// MARK: - Widget

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNext", provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("The hours ahead, ink on paper.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ForkCalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
    }
}
