import SwiftUI

/// A multi-day/all-day event drawn as one continuous bar across day columns.
struct SpanBar: Identifiable {
    let event: CalEvent
    /// Identical copies on other calendars, merged into this bar.
    var duplicates: [CalEvent] = []
    let startIndex: Int
    let endIndex: Int // inclusive
    let lane: Int
    var id: String { eventKey(event) + "-\(startIndex)" }
}

enum SpanLayout {
    private static let byStart: (CalEvent, CalEvent) -> Bool = {
        if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
        return $0.endDate > $1.endDate
    }

    /// Lays out spanning events over the given ordered day columns
    /// (handles gaps, e.g. hidden weekends).
    ///
    /// With `stableLanes`, lane assignment runs over every fetched spanning
    /// event (not just the visible window), so bars keep their row while the
    /// grid side-scrolls; the window merely clips the result. Without it,
    /// lanes pack densely within the window (used by month rows, which don't
    /// slide).
    @MainActor
    static func bars(days: [Date], store: CalendarStore, calendar: Calendar, stableLanes: Bool = false) -> [SpanBar] {
        guard let first = days.first, let last = days.last else { return [] }
        let rangeStart = calendar.startOfDay(for: first)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return [] }
        let dayKeys = days.map { calendar.startOfDay(for: $0) }

        let events = EventLayout.mergeDuplicates(store.spanningEvents(from: rangeStart, to: rangeEnd).sorted(by: byStart))

        var globalLanes: [String: Int] = [:]
        if stableLanes {
            // Greedy sweep in calendar-day ordinals over the full fetched set;
            // an event's lane depends only on its neighbors, not the window.
            let all = EventLayout.mergeDuplicates(store.spanningEvents(from: .distantPast, to: .distantFuture).sorted(by: byStart)).map(\.primary)
            var laneEnds: [Int] = []
            for event in all {
                guard let start = event.startDate, let end = event.endDate else { continue }
                let s = dayOrdinal(calendar.startOfDay(for: start), calendar: calendar, epoch: rangeStart)
                let e = dayOrdinal(calendar.startOfDay(for: max(end.addingTimeInterval(-1), start)), calendar: calendar, epoch: rangeStart)
                if let free = laneEnds.indices.first(where: { laneEnds[$0] < s }) {
                    globalLanes[eventKey(event)] = free
                    laneEnds[free] = e
                } else {
                    globalLanes[eventKey(event)] = laneEnds.count
                    laneEnds.append(e)
                }
            }
        }

        var laneEnds: [Int] = []
        var result: [SpanBar] = []
        for (event, duplicates) in events {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let eventStartDay = calendar.startOfDay(for: start)
            let lastMomentDay = calendar.startOfDay(for: max(end.addingTimeInterval(-1), start))
            guard let startIndex = dayKeys.firstIndex(where: { $0 >= eventStartDay }),
                  let endIndex = dayKeys.lastIndex(where: { $0 <= lastMomentDay }),
                  endIndex >= startIndex else { continue }
            let lane: Int
            if stableLanes {
                lane = globalLanes[eventKey(event)] ?? 0
            } else if let free = laneEnds.firstIndex(where: { $0 < startIndex }) {
                lane = free
                laneEnds[free] = endIndex
            } else {
                lane = laneEnds.count
                laneEnds.append(endIndex)
            }
            result.append(SpanBar(event: event, duplicates: duplicates, startIndex: startIndex, endIndex: endIndex, lane: lane))
        }
        return result
    }

    private static func dayOrdinal(_ day: Date, calendar: Calendar, epoch: Date) -> Int {
        calendar.dateComponents([.day], from: epoch, to: day).day ?? 0
    }
}

struct SpanBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    let event: CalEvent
    var duplicates: [CalEvent] = []
    var compact = false

    /// Calendar colors for this bar: the primary copy plus merged duplicates.
    private var stripColors: [Color] {
        ([event] + duplicates).map { $0.calendar?.displayColor ?? Color.accentColor }
    }

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == eventKey(event)
        let awaiting = store.awaitingResponse(event)
        Text(event.title ?? "Untitled")
            .font(CWT.mono(compact ? 9 : 10, .medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.leading, duplicates.isEmpty ? 6 : CGFloat(3 + 4 * stripColors.count))
            .padding(.trailing, 6)
            .padding(.vertical, compact ? 0 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Rectangle().fill(color.opacity(
                awaiting ? 0.06 : isSelected ? 0.32 : 0.18
            )))
            .overlay(alignment: .leading) {
                if !duplicates.isEmpty {
                    // One strip per calendar this event lives on.
                    HStack(spacing: 1) {
                        ForEach(Array(stripColors.enumerated()), id: \.offset) { _, c in
                            Rectangle().fill(c).frame(width: 3)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            .overlay {
                if awaiting {
                    Rectangle()
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.select(event) }
    }
}
