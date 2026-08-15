import EventKit
import Foundation

struct PositionedEvent: Identifiable {
    let event: EKEvent
    /// Identical copies of this event living on other calendars (merged into
    /// this one block; each contributes a color strip).
    let duplicates: [EKEvent]
    let column: Int
    let columnCount: Int
    var id: String {
        (event.eventIdentifier ?? "new") + "-" + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0)
    }
}

enum EventLayout {
    /// Assigns overlapping events to side-by-side columns within clusters.
    static func layout(_ events: [EKEvent]) -> [PositionedEvent] {
        // Collapse identical events that appear on several calendars into one
        // block. The primary copy is the one worth interacting with: an
        // unanswered invite first (so needs-response styling and RSVP hit the
        // right copy), then any copy where I'm an attendee, then an editable
        // calendar's copy.
        var groups: [String: [EKEvent]] = [:]
        var order: [String] = []
        for event in events {
            let key = (event.title ?? "") + "|"
                + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0) + "|"
                + String(event.endDate?.timeIntervalSinceReferenceDate ?? 0)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(event)
        }
        var merged: [(primary: EKEvent, duplicates: [EKEvent])] = []
        for key in order {
            var copies = groups[key] ?? []
            copies.sort { ($0.calendar?.calendarIdentifier ?? "") < ($1.calendar?.calendarIdentifier ?? "") }
            let primary = copies.first(where: { $0.needsMyResponse })
                ?? copies.first(where: { $0.myParticipantStatus != nil })
                ?? copies.first(where: { $0.calendar?.allowsContentModifications == true })
                ?? copies[0]
            merged.append((primary, copies.filter { $0 !== primary }))
        }

        // Full tiebreaker chain: Swift's sort is unstable, so ties must be
        // deterministic or same-time events swap columns between renders.
        let sorted = merged.sorted {
            if $0.primary.startDate != $1.primary.startDate { return $0.primary.startDate < $1.primary.startDate }
            if $0.primary.endDate != $1.primary.endDate { return $0.primary.endDate > $1.primary.endDate }
            return ($0.primary.eventIdentifier ?? "") < ($1.primary.eventIdentifier ?? "")
        }
        var result: [PositionedEvent] = []
        var clusterAssignments: [(EKEvent, [EKEvent], Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flushCluster() {
            let count = max(columnEnds.count, 1)
            result.append(contentsOf: clusterAssignments.map {
                PositionedEvent(event: $0.0, duplicates: $0.1, column: $0.2, columnCount: count)
            })
            clusterAssignments.removeAll()
            columnEnds.removeAll()
        }

        for (event, duplicates) in sorted {
            guard let start = event.startDate, let end = event.endDate else { continue }
            if start >= clusterEnd, !clusterAssignments.isEmpty {
                flushCluster()
            }
            let column: Int
            if let free = columnEnds.firstIndex(where: { $0 <= start }) {
                column = free
                columnEnds[free] = end
            } else {
                column = columnEnds.count
                columnEnds.append(end)
            }
            clusterAssignments.append((event, duplicates, column))
            clusterEnd = max(clusterEnd, end)
        }
        flushCluster()
        return result
    }
}
