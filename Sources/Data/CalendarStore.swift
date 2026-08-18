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

    /// Primary store — used for new events and write operations on own calendars.
    let eventStore = EKEventStore()
    /// Primary + delegate stores (Gmail shared calendars surface as delegate sources).
    private(set) var allStores: [EKEventStore] = []
    private var calendarOwner: [String: EKEventStore] = [:]

    @Published var accessState: AccessState = .unknown
    @Published var calendars: [EKCalendar] = []
    @Published var events: [EKEvent] = []
    @Published var isRefreshing = false
    @Published var hiddenCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs")
            dayIndexCache = nil
            WidgetBridge.mirror(hiddenCalendarIDs: hiddenCalendarIDs)
        }
    }

    private var fetchedInterval: DateInterval?
    private var undoStack: [UndoAction] = []
    private var searchCache: [EKEvent]?
    private var dayIndexCache: [Date: [EKEvent]]?
    private var bag = Set<AnyCancellable>()

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        allStores = [eventStore]
        WidgetBridge.mirror(
            hiddenCalendarIDs: hiddenCalendarIDs,
            calendarColors: AppSettings.shared.calendarColors,
            showDeclined: AppSettings.shared.showDeclined
        )
        // object: nil so changes from delegate stores are caught too
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.dayIndexCache = nil
                self?.objectWillChange.send()
            }
            .store(in: &bag)
    }

    var defaultCalendar: EKCalendar? {
        eventStore.defaultCalendarForNewEvents
            ?? eventStore.calendars(for: .event).first { $0.allowsContentModifications }
    }

    /// Writable calendars on the primary store (new events / move targets).
    var writableCalendars: [EKCalendar] {
        eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
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
        if accessState == .granted { setupStores() }
    }

    /// Include delegate sources (how Gmail/Exchange shared calendars appear).
    private func setupStores() {
        let delegates = eventStore.delegateSources
        if delegates.isEmpty {
            allStores = [eventStore]
        } else {
            allStores = [eventStore, EKEventStore(sources: delegates)]
        }
        reload()
    }

    /// Ask every source to sync with its server, then re-read locally.
    /// EventKit posts .EKEventStoreChanged when remote changes land, which
    /// triggers another reload() on its own.
    func refresh() {
        guard accessState == .granted else { return }
        isRefreshing = true
        // Google's calendar list is cached for the process; a share whose role
        // changed (reader → writer) stays stale until this is dropped.
        GoogleSync.clearCache()
        for store in allStores { store.refreshSourcesIfNecessary() }
        reload()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.isRefreshing = false
        }
    }

    func reload() {
        guard accessState == .granted else { return }
        var merged: [EKCalendar] = []
        var owners: [String: EKEventStore] = [:]
        for store in allStores {
            for cal in store.calendars(for: .event) {
                merged.append(cal)
                if owners[cal.calendarIdentifier] == nil {
                    owners[cal.calendarIdentifier] = store
                }
            }
        }
        calendars = merged
        calendarOwner = owners
        searchCache = nil
        dayIndexCache = nil
        if let interval = fetchedInterval { fetch(interval) }
        WidgetBridge.reload()
    }

    func owner(of event: EKEvent) -> EKEventStore {
        event.calendar.flatMap { calendarOwner[$0.calendarIdentifier] } ?? eventStore
    }

    func ensureFetched(_ interval: DateInterval) {
        guard accessState == .granted else { return }
        if let fetched = fetchedInterval, fetched.start <= interval.start, fetched.end >= interval.end { return }
        var start = interval.start.addingTimeInterval(-28 * 86400)
        var end = interval.end.addingTimeInterval(28 * 86400)
        // Grow the window instead of replacing it (smooth month/year scrolling)
        if let fetched = fetchedInterval {
            start = min(start, fetched.start)
            end = max(end, fetched.end)
        }
        // Cap the span so refetches stay fast
        if end.timeIntervalSince(start) > 400 * 86400 {
            start = interval.start.addingTimeInterval(-45 * 86400)
            end = interval.end.addingTimeInterval(45 * 86400)
        }
        fetchedInterval = DateInterval(start: start, end: end)
        fetch(fetchedInterval!)
    }

    private let fetchQueue = DispatchQueue(label: "com.cwandt.forkcalendar.fetch", qos: .userInitiated)
    private var fetchGeneration = 0

    /// Fetches off the main thread so saves/navigation never beachball.
    private func fetch(_ interval: DateInterval) {
        fetchGeneration += 1
        let generation = fetchGeneration
        let stores = allStores
        fetchQueue.async { [weak self] in
            var merged: [EKEvent] = []
            for store in stores {
                let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
                merged.append(contentsOf: store.events(matching: predicate))
            }
            // Deterministic tiebreaker — an unstable sort lets same-time events
            // reorder across refetches (columns/colors jump while scrolling).
            merged.sort {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return ($0.eventIdentifier ?? "") < ($1.eventIdentifier ?? "")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.fetchGeneration == generation else { return }
                    self.events = merged
                    self.dayIndexCache = nil
                    // Drop RSVP overrides once EventKit reflects the answer
                    self.rsvpOverrides = self.rsvpOverrides.filter { key, _ in
                        guard let match = merged.first(where: { eventKey($0) == key }) else { return true }
                        return match.needsMyResponse
                    }
                }
            }
        }
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

    private func passesFilters(_ event: EKEvent) -> Bool {
        guard let cal = event.calendar, isVisible(cal) else { return false }
        if !AppSettings.shared.showDeclined, isDeclined(event) { return false }
        return true
    }

    /// Visible events overlapping the given day, split into all-day/multi-day
    /// and timed. Backed by the per-day index so scrolling renders stay cheap.
    func events(on day: Date, calendar: Calendar) -> (allDay: [EKEvent], timed: [EKEvent]) {
        let key = calendar.startOfDay(for: day)
        var allDay: [EKEvent] = []
        var timed: [EKEvent] = []
        for event in dayIndex()[key] ?? [] {
            guard let start = event.startDate, let end = event.endDate else { continue }
            if event.isAllDay || end.timeIntervalSince(start) >= 86400 {
                allDay.append(event)
            } else {
                timed.append(event)
            }
        }
        return (allDay, timed)
    }

    // MARK: - RSVP overlay (optimistic, until CalDAV syncs Google's answer back)

    @Published var rsvpOverrides: [String: EKParticipantStatus] = [:]

    /// Keyed on the invite's shared UID + this occurrence's start, so an RSVP
    /// answered on one calendar's copy shows on every copy of that occurrence
    /// (eventIdentifier differs per copy) without leaking across a series.
    private func rsvpKey(_ event: EKEvent) -> String {
        let id = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "new"
        return id + "-" + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0)
    }

    func setRSVPOverride(_ status: EKParticipantStatus, for event: EKEvent) {
        rsvpOverrides[rsvpKey(event)] = status
        eventStore.refreshSourcesIfNecessary()
    }

    /// True when the event still needs my response (accounting for a
    /// just-sent RSVP that EventKit hasn't synced yet).
    func awaitingResponse(_ event: EKEvent) -> Bool {
        guard rsvpOverrides[rsvpKey(event)] == nil else { return false }
        return event.needsMyResponse
    }

    func effectiveStatus(_ event: EKEvent) -> EKParticipantStatus? {
        rsvpOverrides[rsvpKey(event)] ?? event.myParticipantStatus
    }

    /// All-day and multi-day events overlapping the interval (for span bars).
    func spanningEvents(from: Date, to: Date) -> [EKEvent] {
        events.filter { event in
            guard passesFilters(event) else { return false }
            guard let start = event.startDate, let end = event.endDate else { return false }
            guard event.isAllDay || end.timeIntervalSince(start) >= 86400 else { return false }
            return start < to && end > from
        }
    }

    /// Fast per-day lookup for dense views (year view dots).
    private func dayIndex() -> [Date: [EKEvent]] {
        if let cached = dayIndexCache { return cached }
        let cal = Calendar.autoupdatingCurrent
        var index: [Date: [EKEvent]] = [:]
        for event in events {
            guard passesFilters(event) else { continue }
            guard let start = event.startDate, let end = event.endDate else { continue }
            var day = cal.startOfDay(for: start)
            var hops = 0
            while day < end, hops < 62 {
                index[day, default: []].append(event)
                day = cal.date(byAdding: .day, value: 1, to: day) ?? end
                hops += 1
            }
        }
        dayIndexCache = index
        return index
    }

    func eventColors(on day: Date, calendar: Calendar, max maxCount: Int = 3) -> [Color] {
        let key = calendar.startOfDay(for: day)
        let dayEvents = dayIndex()[key] ?? []
        return dayEvents.prefix(maxCount).map { $0.calendar?.displayColor ?? .accentColor }
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
            var merged: [EKEvent] = []
            for store in allStores {
                let predicate = store.predicateForEvents(
                    withStart: Date().addingTimeInterval(-365 * 86400),
                    end: Date().addingTimeInterval(365 * 86400),
                    calendars: nil
                )
                merged.append(contentsOf: store.events(matching: predicate))
            }
            searchCache = merged.sorted { $0.startDate < $1.startDate }
        }
        let now = Date()
        return (searchCache ?? [])
            .filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
            .sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    // MARK: - Mutations + undo

    func saveWithUndo(_ event: EKEvent, snapshot: EventSnapshot?, isNew: Bool, span: EKSpan) {
        do {
            try owner(of: event).save(event, span: span, commit: true)
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
            try owner(of: event).remove(event, span: span, commit: true)
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
        if copy.calendar == nil || !copy.calendar.allowsContentModifications
            || calendarOwner[copy.calendar.calendarIdentifier] !== eventStore {
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
                try? owner(of: event).save(event, span: .thisEvent, commit: true)
            }
        case .recreate(let snapshot):
            let event = EKEvent(eventStore: eventStore)
            snapshot.apply(to: event, in: self)
            if event.calendar == nil || calendarOwner[event.calendar.calendarIdentifier] !== eventStore {
                event.calendar = defaultCalendar
            }
            try? eventStore.save(event, span: .thisEvent, commit: true)
        case .remove(let id):
            if let event = findEvent(id: id) {
                try? owner(of: event).remove(event, span: .thisEvent, commit: true)
            }
        }
        reload()
    }

    private func findEvent(id: String) -> EKEvent? {
        if let match = events.first(where: { $0.eventIdentifier == id }) { return match }
        for store in allStores {
            if let match = store.event(withIdentifier: id) { return match }
        }
        return nil
    }
}
