import Foundation

struct PositionedEvent: Identifiable {
    let event: CalEvent
    /// Identical copies of this event living on other calendars (merged into
    /// this one block; each contributes a color strip).
    let duplicates: [CalEvent]
    let column: Int
    let columnCount: Int
    var id: String { eventKey(event) }
}

enum EventLayout {
    /// Collapse identical events (same title, start, end) that appear on
    /// several calendars into (primary, duplicates) pairs, preserving input
    /// order. The primary copy is the one worth interacting with: an
    /// unanswered invite first (so needs-response styling and RSVP hit the
    /// right copy), then any copy where I'm an attendee, then an editable
    /// calendar's copy.
    static func mergeDuplicates(_ events: [CalEvent], rank: ((CalEvent) -> Int)? = nil) -> [(primary: CalEvent, duplicates: [CalEvent])] {
        var groups: [String: [CalEvent]] = [:]
        var order: [String] = []
        for event in events {
            let key = (event.title ?? "") + "|"
                + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0) + "|"
                + String(event.endDate?.timeIntervalSinceReferenceDate ?? 0)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(event)
        }
        var merged: [(primary: CalEvent, duplicates: [CalEvent])] = []
        for key in order {
            var copies = groups[key] ?? []
            // Sidebar order when provided (top calendar first — it wins the
            // primary fallback, so the block tints to the top calendar);
            // identifier as the deterministic tiebreaker.
            copies.sort {
                let r0 = rank?($0) ?? 0, r1 = rank?($1) ?? 0
                if r0 != r1 { return r0 < r1 }
                return ($0.calendar?.calendarIdentifier ?? "") < ($1.calendar?.calendarIdentifier ?? "")
            }
            // Sidebar order wins outright — even over a copy awaiting my RSVP
            // (its strip still renders dashed; responding happens on the
            // invite copy via the panel). With no rank, fall back to the old
            // interaction-preference chain.
            let primary: CalEvent
            if rank != nil {
                primary = copies[0]
            } else {
                primary = copies.first(where: { $0.needsMyResponse })
                    ?? copies.first(where: { $0.myParticipantStatus != nil })
                    ?? copies.first(where: { $0.calendar?.allowsContentModifications == true })
                    ?? copies[0]
            }
            merged.append((primary, copies.filter { $0 !== primary }))
        }
        return merged
    }

    /// Assigns overlapping events to side-by-side columns within clusters.
    static func layout(_ events: [CalEvent], rank: ((CalEvent) -> Int)? = nil) -> [PositionedEvent] {
        let merged = mergeDuplicates(events, rank: rank)

        // Full tiebreaker chain: Swift's sort is unstable, so ties must be
        // deterministic or same-time events swap columns between renders.
        let sorted = merged.sorted {
            if $0.primary.startDate != $1.primary.startDate { return $0.primary.startDate < $1.primary.startDate }
            if $0.primary.endDate != $1.primary.endDate { return $0.primary.endDate > $1.primary.endDate }
            return ($0.primary.eventIdentifier ?? "") < ($1.primary.eventIdentifier ?? "")
        }
        var result: [PositionedEvent] = []
        var clusterAssignments: [(CalEvent, [CalEvent], Int)] = []
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
