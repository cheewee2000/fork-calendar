import WidgetKit
import SwiftUI

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

// MARK: - Formatting

enum WFmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()

    /// "9:00 AM" → "9:00a", 24h locales stay "14:00". With `Fmt.hour`: "9 AM" → "9a".
    static func compact(_ d: Date, _ formatter: DateFormatter = time) -> String {
        String(formatter.string(from: d)
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

// MARK: - Grid layout

/// The time grid's window and block columns. It starts on the current hour, or on the
/// next event's hour when nothing is left within `hours` of now.
struct GridLayout {
    struct Block: Identifiable {
        let event: WidgetEvent
        let column: Int
        let columnCount: Int
        var id: String { event.id }
    }
    let start: Date
    let blocks: [Block]

    init(events: [WidgetEvent], now: Date, hours: Int) {
        let cal = Calendar.autoupdatingCurrent
        func hourStart(_ d: Date) -> Date { cal.dateInterval(of: .hour, for: d)?.start ?? d }
        let span = TimeInterval(hours) * 3600
        // Unfinished timed events; ties ordered so columns don't swap between renders.
        let timed = events.filter { !$0.isAllDay && $0.end > now }
            .sorted { ($0.start, $1.end, $0.id) < ($1.start, $0.end, $1.id) }
        var top = hourStart(now)
        if let next = timed.first, next.start >= top + span { top = hourStart(next.start) }
        start = top

        // Overlapping events share the width side by side within their cluster
        // (the app's EventLayout rule).
        var out: [Block] = []
        var cluster: [(event: WidgetEvent, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            out += cluster.map { Block(event: $0.event, column: $0.column, columnCount: columnEnds.count) }
            cluster.removeAll()
            columnEnds.removeAll()
        }
        for e in timed where e.start < top + span {
            if e.start >= clusterEnd { flush() }
            let column = columnEnds.firstIndex { $0 <= e.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(e.end) } else { columnEnds[column] = e.end }
            cluster.append((e, column))
            clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        blocks = out
    }
}

#if DEBUG
extension GridLayout {
    /// Self-check: asserts the window start, the ended/all-day filter and the columns.
    static func demo() {
        let t0 = Calendar.autoupdatingCurrent.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
            .addingTimeInterval(14 * 3600)   // 2pm
        func ev(_ id: String, _ from: Double, _ to: Double, allDay: Bool = false) -> WidgetEvent {
            WidgetEvent(id: id, title: id, start: t0.addingTimeInterval(from * 3600),
                        end: t0.addingTimeInterval(to * 3600), isAllDay: allDay, color: .black)
        }
        let now = t0.addingTimeInterval(40 * 60)   // 2:40pm
        let grid = GridLayout(events: [
            ev("ended", -1, 0.5), ev("current", 0, 1), ev("overlap", 0.5, 1.5), ev("later", 2, 3),
            ev("far", 9, 10), ev("allday", -14, 10, allDay: true),
        ], now: now, hours: 4)
        assert(grid.start == t0)
        assert(grid.blocks.map(\.id) == ["current", "overlap", "later"])
        assert(grid.blocks.map(\.column) == [0, 1, 0] && grid.blocks.map(\.columnCount) == [2, 2, 1])
        let jumped = GridLayout(events: [ev("far", 9.5, 10)], now: now, hours: 4)
        assert(jumped.start == t0.addingTimeInterval(9 * 3600) && jumped.blocks.count == 1)
    }
}
#endif

// MARK: - Views

/// An event the way the app's time grid draws it: calendar-color strip, tinted fill.
struct BlockView: View {
    let event: WidgetEvent
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(event.title)
                .font(CWT.mono(10))
                .lineLimit(1)
            if height >= 26 {
                Text("\(WFmt.compact(event.start))–\(WFmt.compact(event.end))")
                    .font(CWT.mono(8))
                    .opacity(0.75)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(event.color)
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Paper under the tint, so the hour lines don't strike through the text.
        .background(event.color.opacity(0.16))
        .background(CWT.paper)
        .overlay(alignment: .leading) { Rectangle().fill(event.color).frame(width: 2) }
        .clipped()
    }
}

/// Mini day view: the hours from now on, unfinished events as blocks sized by duration.
struct TimeGrid: View {
    let entry: UpNextEntry
    private let gutter: CGFloat = 22

    var body: some View {
        let allDay = DaySlice(entry).today.filter(\.isAllDay)
        VStack(alignment: .leading, spacing: 3) {
            if let first = allDay.first {
                HStack(spacing: 0) {
                    Text(allDay.count > 1 ? "+\(allDay.count - 1)" : "ALL")
                        .font(CWT.mono(9))
                        .foregroundStyle(CWT.inkFaint)
                        .frame(width: gutter, alignment: .leading)
                    BlockView(event: first, height: 14)
                }
                .frame(height: 14)
            }
            GeometryReader { geo in grid(in: geo.size) }
        }
    }

    private func grid(in size: CGSize) -> some View {
        let hours = max(2, Int(size.height / 22))
        let layout = GridLayout(events: entry.events, now: entry.date, hours: hours)
        // A grid that jumped ahead to tomorrow says so above its first hour.
        let jumped = !layout.start.isSameDay(as: entry.date)
        let top: CGFloat = jumped ? 13 : 0
        let hourHeight = (size.height - top) / CGFloat(hours)
        func y(_ d: Date) -> CGFloat { top + CGFloat(d.timeIntervalSince(layout.start) / 3600) * hourHeight }
        let width = size.width - gutter
        return ZStack(alignment: .topLeading) {
            if jumped {
                Text("TOMORROW")
                    .font(CWT.mono(9))
                    .foregroundStyle(CWT.inkFaint)
            }
            ForEach(0..<hours, id: \.self) { i in
                let hour = layout.start.addingTimeInterval(TimeInterval(i) * 3600)
                Rectangle().fill(CWT.rule)
                    .frame(width: width, height: 1)
                    .offset(x: gutter, y: y(hour))
                Text(WFmt.compact(hour, Fmt.hour))
                    .font(CWT.mono(9))
                    .foregroundStyle(CWT.inkFaint)
                    .offset(y: y(hour))
            }
            ForEach(layout.blocks) { block in
                // A block already underway is cut off at the top of the grid.
                let y0 = max(y(block.event.start), top)
                let height = max(min(y(block.event.end), size.height) - y0 - 1, 13)
                let column = width / CGFloat(block.columnCount)
                BlockView(event: block.event, height: height)
                    .frame(width: column - 1, height: height)
                    .offset(x: gutter + column * CGFloat(block.column), y: y0 + 1)
            }
            // Off the top (clipped) whenever the grid starts later than now.
            Rectangle().fill(CWT.signalRed)
                .frame(width: width, height: 1)
                .offset(x: gutter, y: y(entry.date))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

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
            TimeGrid(entry: entry)
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
            TimeGrid(entry: entry)
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
            TimeGrid(entry: entry)
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
