import EventKit
import Foundation

struct PositionedEvent: Identifiable {
    let event: EKEvent
    let column: Int
    let columnCount: Int
    var id: String {
        (event.eventIdentifier ?? "new") + "-" + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0)
    }
}

enum EventLayout {
    /// Assigns overlapping events to side-by-side columns within clusters.
    static func layout(_ events: [EKEvent]) -> [PositionedEvent] {
        let sorted = events.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.endDate > $1.endDate
        }
        var result: [PositionedEvent] = []
        var clusterAssignments: [(EKEvent, Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flushCluster() {
            let count = max(columnEnds.count, 1)
            result.append(contentsOf: clusterAssignments.map {
                PositionedEvent(event: $0.0, column: $0.1, columnCount: count)
            })
            clusterAssignments.removeAll()
            columnEnds.removeAll()
        }

        for event in sorted {
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
            clusterAssignments.append((event, column))
            clusterEnd = max(clusterEnd, end)
        }
        flushCluster()
        return result
    }
}
