import EventKit
import SwiftUI

/// A multi-day/all-day event drawn as one continuous bar across day columns.
struct SpanBar: Identifiable {
    let event: EKEvent
    let startIndex: Int
    let endIndex: Int // inclusive
    let lane: Int
    var id: String { eventKey(event) + "-\(startIndex)" }
}

enum SpanLayout {
    /// Lays out spanning events over the given ordered day columns
    /// (handles gaps, e.g. hidden weekends).
    @MainActor
    static func bars(days: [Date], store: CalendarStore, calendar: Calendar) -> [SpanBar] {
        guard let first = days.first, let last = days.last else { return [] }
        let rangeStart = calendar.startOfDay(for: first)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return [] }
        let dayKeys = days.map { calendar.startOfDay(for: $0) }

        let events = store.spanningEvents(from: rangeStart, to: rangeEnd).sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.endDate > $1.endDate
        }

        var laneEnds: [Int] = []
        var result: [SpanBar] = []
        for event in events {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let eventStartDay = calendar.startOfDay(for: start)
            let lastMomentDay = calendar.startOfDay(for: max(end.addingTimeInterval(-1), start))
            guard let startIndex = dayKeys.firstIndex(where: { $0 >= eventStartDay }),
                  let endIndex = dayKeys.lastIndex(where: { $0 <= lastMomentDay }),
                  endIndex >= startIndex else { continue }
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 < startIndex }) {
                lane = free
                laneEnds[free] = endIndex
            } else {
                lane = laneEnds.count
                laneEnds.append(endIndex)
            }
            result.append(SpanBar(event: event, startIndex: startIndex, endIndex: endIndex, lane: lane))
        }
        return result
    }
}

struct SpanBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: CalendarStore
    let event: EKEvent
    var compact = false

    var body: some View {
        let color = event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == eventKey(event)
        let awaiting = store.awaitingResponse(event)
        Text(event.title ?? "Untitled")
            .font(.system(size: compact ? 9 : 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, compact ? 0 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(
                awaiting ? 0.06 : isSelected ? 0.32 : 0.18
            )))
            .overlay {
                if awaiting {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.select(event) }
    }
}
