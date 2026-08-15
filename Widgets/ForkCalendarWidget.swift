import WidgetKit
import SwiftUI
import EventKit

// MARK: - Model

struct WidgetEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

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
        // Re-render at every event boundary until midnight, then start over.
        let cal = Calendar.autoupdatingCurrent
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(86400)
        var dates: Set<Date> = [now, midnight]
        for e in current.events where !e.isAllDay {
            if e.start > now, e.start < midnight { dates.insert(e.start) }
            if e.end > now, e.end < midnight { dates.insert(e.end) }
        }
        let entries = dates.sorted().prefix(30).map {
            UpNextEntry(date: $0, hasAccess: true, events: current.events)
        }
        completion(Timeline(entries: Array(entries), policy: .atEnd))
    }

    private func load(at date: Date) -> UpNextEntry {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return UpNextEntry(date: date, hasAccess: false, events: [])
        }
        let store = EKEventStore()
        var stores = [store]
        let delegates = store.delegateSources
        if !delegates.isEmpty { stores.append(EKEventStore(sources: delegates)) }

        let shared = UserDefaults(suiteName: "group.com.cwandt.forkcalendar")
        let hidden = Set(shared?.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        let colorOverrides = shared?.dictionary(forKey: "calendarColors") as? [String: String] ?? [:]
        let showDeclined = shared?.object(forKey: "showDeclined") as? Bool ?? true

        let cal = Calendar.autoupdatingCurrent
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(172800)

        var merged: [EKEvent] = []
        for s in stores {
            let predicate = s.predicateForEvents(withStart: start, end: end, calendars: nil)
            merged.append(contentsOf: s.events(matching: predicate))
        }
        merged.sort {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return ($0.eventIdentifier ?? "") < ($1.eventIdentifier ?? "")
        }

        var seen = Set<String>()
        var events: [WidgetEvent] = []
        for e in merged {
            guard let calendar = e.calendar, let startDate = e.startDate, let endDate = e.endDate else { continue }
            if hidden.contains(calendar.calendarIdentifier) { continue }
            if !showDeclined,
               e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined { continue }
            // Same event mirrored across calendars/stores collapses to one row.
            let title = e.title ?? "Untitled"
            let key = "\(title)|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { continue }

            var color = Color(hex: "7D6378")!
            if let hex = colorOverrides[calendar.calendarIdentifier], let c = Color(hex: hex) {
                color = c
            } else if let cg = calendar.cgColor {
                color = Color(cgColor: cg)
            }
            events.append(WidgetEvent(
                id: (e.eventIdentifier ?? key) + String(startDate.timeIntervalSince1970),
                title: title, start: startDate, end: endDate,
                isAllDay: e.isAllDay || endDate.timeIntervalSince(startDate) >= 86400,
                color: color
            ))
        }
        return UpNextEntry(date: date, hasAccess: true, events: events)
    }
}

// MARK: - Formatting

enum WFmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    static let month: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()
    static let dayNum: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()

    /// "9:00 AM" → "9:00a", 24h locales stay "14:00".
    static func compact(_ d: Date) -> String {
        String(time.string(from: d)
            .replacingOccurrences(of: "AM", with: "a")
            .replacingOccurrences(of: "PM", with: "p")
            .filter { !$0.isWhitespace })
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

struct EventRow: View {
    let event: WidgetEvent
    let now: Date

    private var isNow: Bool { !event.isAllDay && event.start <= now && now < event.end }

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(event.color).frame(width: 2)
            Text(event.isAllDay ? "ALL" : WFmt.compact(event.start))
                .font(CWT.mono(11))
                .foregroundStyle(isNow ? CWT.signalRed : CWT.inkFaint)
                .frame(width: 44, alignment: .leading)
            Text(event.title)
                .font(CWT.mono(11, isNow ? .bold : .regular))
                .foregroundStyle(CWT.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 15)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(CWT.mono(9, .bold))
            .foregroundStyle(CWT.inkFaint)
            .frame(height: 12)
    }
}

struct MoreLabel: View {
    let count: Int
    var body: some View {
        Text("+\(count) MORE")
            .font(CWT.mono(9))
            .foregroundStyle(CWT.inkFaint)
    }
}

struct EmptyLabel: View {
    var body: some View {
        Text("NO EVENTS")
            .font(CWT.mono(10))
            .foregroundStyle(CWT.inkFaint)
    }
}

/// Event list that spills into tomorrow when today runs dry.
struct RowList: View {
    let entry: UpNextEntry
    let limit: Int

    var body: some View {
        let slice = DaySlice(entry)
        VStack(alignment: .leading, spacing: 3) {
            if slice.today.isEmpty && slice.tomorrow.isEmpty {
                EmptyLabel()
            } else if slice.today.isEmpty {
                SectionLabel(text: "TOMORROW")
                ForEach(slice.tomorrow.prefix(limit - 1)) { EventRow(event: $0, now: entry.date) }
                if slice.tomorrow.count > limit - 1 { MoreLabel(count: slice.tomorrow.count - (limit - 1)) }
            } else {
                ForEach(slice.today.prefix(limit)) { EventRow(event: $0, now: entry.date) }
                if slice.today.count > limit {
                    MoreLabel(count: slice.today.count - limit)
                } else if slice.today.count + 2 <= limit, !slice.tomorrow.isEmpty {
                    SectionLabel(text: "TOMORROW")
                    ForEach(slice.tomorrow.prefix(limit - slice.today.count - 1)) {
                        EventRow(event: $0, now: entry.date)
                    }
                }
            }
        }
    }
}

struct SmallView: View {
    let entry: UpNextEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(WFmt.weekday.string(from: entry.date).uppercased())
                    .font(CWT.mono(11, .bold))
                    .foregroundStyle(CWT.inkFaint)
                Spacer()
                Text(WFmt.dayNum.string(from: entry.date))
                    .font(CWT.mono(18, .bold))
                    .foregroundStyle(CWT.ink)
            }
            Rectangle().fill(CWT.rule).frame(height: 1)
            RowList(entry: entry, limit: 4)
            Spacer(minLength: 0)
        }
    }
}

struct MediumView: View {
    let entry: UpNextEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WFmt.weekday.string(from: entry.date).uppercased())
                    .font(CWT.mono(11, .bold))
                    .foregroundStyle(CWT.inkFaint)
                Text(WFmt.dayNum.string(from: entry.date))
                    .font(CWT.mono(30, .bold))
                    .foregroundStyle(CWT.ink)
                Text(WFmt.month.string(from: entry.date).uppercased())
                    .font(CWT.mono(11))
                    .foregroundStyle(CWT.inkFaint)
                Spacer(minLength: 0)
            }
            Rectangle().fill(CWT.rule).frame(width: 1)
            VStack(alignment: .leading) {
                RowList(entry: entry, limit: 6)
                Spacer(minLength: 0)
            }
        }
    }
}

struct LargeView: View {
    let entry: UpNextEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(WFmt.weekday.string(from: entry.date).uppercased())
                    .font(CWT.mono(12, .bold))
                    .foregroundStyle(CWT.inkFaint)
                Spacer()
                Text("\(WFmt.month.string(from: entry.date).uppercased()) \(WFmt.dayNum.string(from: entry.date))")
                    .font(CWT.mono(12, .bold))
                    .foregroundStyle(CWT.ink)
            }
            Rectangle().fill(CWT.rule).frame(height: 1)
            RowList(entry: entry, limit: 14)
            Spacer(minLength: 0)
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
                    .font(CWT.mono(13, .bold))
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
                .font(CWT.mono(10, .bold))
                .foregroundStyle(CWT.ink)
            Text("Open the app to allow calendar access")
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
                case .systemMedium: MediumView(entry: entry)
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
        .description("Today's events, ink on paper.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ForkCalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
    }
}
