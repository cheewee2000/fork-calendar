import EventKit
import SwiftUI

@MainActor
final class CalendarStore: ObservableObject {
    enum AccessState { case unknown, granted, denied }

    let eventStore = EKEventStore()

    @Published var accessState: AccessState = .unknown
    @Published var calendars: [EKCalendar] = []
    @Published var events: [EKEvent] = []
    @Published var hiddenCalendarIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs") }
    }

    private var fetchedInterval: DateInterval?

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    var defaultCalendar: EKCalendar? {
        eventStore.defaultCalendarForNewEvents ?? calendars.first { $0.allowsContentModifications }
    }

    var writableCalendars: [EKCalendar] {
        calendars.filter { $0.allowsContentModifications }
    }

    var calendarsBySource: [(source: String, calendars: [EKCalendar])] {
        let groups = Dictionary(grouping: calendars) { $0.source?.title ?? "Other" }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.title < $1.title }) }
    }

    func requestAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            accessState = .granted
        case .denied, .restricted, .writeOnly:
            accessState = .denied
        default:
            do {
                accessState = try await eventStore.requestFullAccessToEvents() ? .granted : .denied
            } catch {
                accessState = .denied
            }
        }
        if accessState == .granted { reload() }
    }

    func ensureFetched(_ interval: DateInterval) {
        guard accessState == .granted else { return }
        if let fetched = fetchedInterval, fetched.start <= interval.start, fetched.end >= interval.end { return }
        // Fetch with a buffer so week-to-week navigation doesn't refetch
        let buffered = DateInterval(
            start: interval.start.addingTimeInterval(-28 * 86400),
            end: interval.end.addingTimeInterval(28 * 86400)
        )
        fetchedInterval = buffered
        fetch(buffered)
    }

    func reload() {
        guard accessState == .granted else { return }
        calendars = eventStore.calendars(for: .event)
        if let interval = fetchedInterval { fetch(interval) }
    }

    private func fetch(_ interval: DateInterval) {
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func isVisible(_ calendar: EKCalendar) -> Bool {
        !hiddenCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func toggle(_ calendar: EKCalendar) {
        if hiddenCalendarIDs.contains(calendar.calendarIdentifier) {
            hiddenCalendarIDs.remove(calendar.calendarIdentifier)
        } else {
            hiddenCalendarIDs.insert(calendar.calendarIdentifier)
        }
    }

    /// Visible events overlapping the given day, split into all-day/multi-day and timed.
    func events(on day: Date, calendar: Calendar) -> (allDay: [EKEvent], timed: [EKEvent]) {
        guard let dayInterval = calendar.dateInterval(of: .day, for: day) else { return ([], []) }
        var allDay: [EKEvent] = []
        var timed: [EKEvent] = []
        for event in events {
            guard let cal = event.calendar, isVisible(cal) else { continue }
            guard let start = event.startDate, let end = event.endDate else { continue }
            guard start < dayInterval.end, end > dayInterval.start else { continue }
            if event.isAllDay || end.timeIntervalSince(start) >= 86400 {
                allDay.append(event)
            } else {
                timed.append(event)
            }
        }
        return (allDay, timed)
    }

    func save(_ event: EKEvent) {
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            print("Save failed: \(error)")
        }
        reload()
    }

    func delete(_ event: EKEvent) {
        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
        } catch {
            print("Delete failed: \(error)")
        }
        reload()
    }
}
