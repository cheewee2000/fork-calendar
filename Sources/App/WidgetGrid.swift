import SwiftUI

// The mini time grid the iOS widget and the macOS menu bar dropdown both draw.

struct WidgetEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    /// Video-call link; the block grows a JOIN chip (menu bar only, the widget never sets it).
    var joinURL: URL? = nil
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
        // Beside the times when there's a second row, so it doesn't squeeze the title.
        let join = event.joinURL.map { url in
            Link(destination: url) {
                Text("JOIN")
                    .font(CWT.mono(9))
                    .foregroundStyle(CWT.paper)
                    .padding(.horizontal, 4)
                    .background(event.color)
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(event.title)
                    .font(CWT.mono(10))
                    .lineLimit(1)
                if height < 26 {
                    Spacer(minLength: 0)
                    join
                }
            }
            if height >= 26 {
                HStack(spacing: 2) {
                    Text("\(WFmt.compact(event.start))–\(WFmt.compact(event.end))")
                        .font(CWT.mono(8))
                        .opacity(0.75)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    join
                }
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
    let events: [WidgetEvent]
    let now: Date
    /// Smallest hour row; the grid shows as many whole hours as fit at this height.
    var hourHeight: CGFloat = 22
    private let gutter: CGFloat = 22

    var body: some View {
        let cal = Calendar.autoupdatingCurrent
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(86400)
        let allDay = events.filter { $0.isAllDay && $0.start < midnight && $0.end > now }
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
        let hours = max(2, Int(size.height / hourHeight))
        let layout = GridLayout(events: events, now: now, hours: hours)
        // A grid that jumped ahead to tomorrow says so above its first hour.
        let jumped = !layout.start.isSameDay(as: now)
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
                .offset(x: gutter, y: y(now))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}
