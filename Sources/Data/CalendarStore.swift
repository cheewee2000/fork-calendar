import EventKit
import SwiftUI
import Combine

struct EventSnapshot {
    var title: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String?
    var location: String?
    var notes: String?
    var url: URL?

    init(_ event: EKEvent) {
        title = event.title
        start = event.startDate ?? Date()
        end = event.endDate ?? Date()
        isAllDay = event.isAllDay
        calendarID = event.calendar?.calendarIdentifier
        location = event.location
        notes = event.notes
        url = event.url
    }

    @MainActor
    func apply(to event: EKEvent, in store: CalendarStore) {
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location
        event.notes = notes
        event.url = url
        if let calendarID, let cal = store.calendars.first(where: { $0.calendarIdentifier == calendarID }) {
            event.calendar = cal
        }
    }
}

enum UndoAction {
    case restore(id: String, snapshot: EventSnapshot)
    case recreate(snapshot: EventSnapshot)
    case remove(id: String)
}

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
    private var undoStack: [UndoAction] = []
    private var searchCache: [EKEvent]?
    private var bag = Set<AnyCancellable>()

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
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
        searchCache = nil
        if let interval = fetchedInterval { fetch(interval) }
    }

    private func fetch(_ interval: DateInterval) {
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Visibility

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

    private func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    /// Visible events overlapping the given day, split into all-day/multi-day and timed.
    func events(on day: Date, calendar: Calendar) -> (allDay: [EKEvent], timed: [EKEvent]) {
        guard let dayInterval = calendar.dateInterval(of: .day, for: day) else { return ([], []) }
        let showDeclined = AppSettings.shared.showDeclined
        var allDay: [EKEvent] = []
        var timed: [EKEvent] = []
        for event in events {
            guard let cal = event.calendar, isVisible(cal) else { continue }
            guard let start = event.startDate, let end = event.endDate else { continue }
            guard start < dayInterval.end, end > dayInterval.start else { continue }
            if !showDeclined, isDeclined(event) { continue }
            if event.isAllDay || end.timeIntervalSince(start) >= 86400 {
                allDay.append(event)
            } else {
                timed.append(event)
            }
        }
        return (allDay, timed)
    }

    /// Upcoming timed event today (for the menu bar).
    var nextUpcomingEvent: EKEvent? {
        let now = Date()
        let cal = Calendar.autoupdatingCurrent
        return events.first {
            guard let cal2 = $0.calendar, isVisible(cal2), !$0.isAllDay else { return false }
            guard let s = $0.startDate else { return false }
            return s > now && cal.isDateInToday(s)
        }
    }

    // MARK: - Search (±1 year)

    func searchEvents(_ query: String) -> [EKEvent] {
        guard accessState == .granted, query.count >= 2 else { return [] }
        if searchCache == nil {
            let predicate = eventStore.predicateForEvents(
                withStart: Date().addingTimeInterval(-365 * 86400),
                end: Date().addingTimeInterval(365 * 86400),
                calendars: nil
            )
            searchCache = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        }
        let now = Date()
        return (searchCache ?? [])
            .filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    // MARK: - Mutations + undo

    func saveWithUndo(_ event: EKEvent, snapshot: EventSnapshot?, isNew: Bool, span: EKSpan) {
        do {
            try eventStore.save(event, span: span, commit: true)
            if isNew {
                if let id = event.eventIdentifier { undoStack.append(.remove(id: id)) }
            } else if let snapshot, let id = event.eventIdentifier {
                undoStack.append(.restore(id: id, snapshot: snapshot))
            }
        } catch {
            print("Save failed: \(error)")
        }
        reload()
    }

    func deleteWithUndo(_ event: EKEvent, span: EKSpan) {
        let snapshot = EventSnapshot(event)
        do {
            try eventStore.remove(event, span: span, commit: true)
            undoStack.append(.recreate(snapshot: snapshot))
        } catch {
            print("Delete failed: \(error)")
        }
        reload()
    }

    func duplicate(_ event: EKEvent, dayOffset: Double = 0) {
        let copy = EKEvent(eventStore: eventStore)
        var snapshot = EventSnapshot(event)
        snapshot.start = snapshot.start.addingTimeInterval(dayOffset * 86400)
        snapshot.end = snapshot.end.addingTimeInterval(dayOffset * 86400)
        snapshot.apply(to: copy, in: self)
        if copy.calendar == nil || !copy.calendar.allowsContentModifications {
            copy.calendar = defaultCalendar
        }
        saveWithUndo(copy, snapshot: nil, isNew: true, span: .thisEvent)
    }

    func move(_ event: EKEvent, to calendar: EKCalendar) {
        let snapshot = EventSnapshot(event)
        event.calendar = calendar
        saveWithUndo(event, snapshot: snapshot, isNew: false, span: .thisEvent)
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .restore(let id, let snapshot):
            if let event = findEvent(id: id) {
                snapshot.apply(to: event, in: self)
                try? eventStore.save(event, span: .thisEvent, commit: true)
            }
        case .recreate(let snapshot):
            let event = EKEvent(eventStore: eventStore)
            snapshot.apply(to: event, in: self)
            if event.calendar == nil { event.calendar = defaultCalendar }
            try? eventStore.save(event, span: .thisEvent, commit: true)
        case .remove(let id):
            if let event = findEvent(id: id) {
                try? eventStore.remove(event, span: .thisEvent, commit: true)
            }
        }
        reload()
    }

    private func findEvent(id: String) -> EKEvent? {
        events.first { $0.eventIdentifier == id } ?? eventStore.event(withIdentifier: id)
    }
}
