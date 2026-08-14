import SwiftUI
import EventKit

enum ViewMode: Hashable {
    case day
    case week
    case days(Int)
    case month
    case year

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .days(let n): return "\(n) days"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
}

struct EditorContext: Identifiable {
    let id = UUID()
    let event: EKEvent
    let isNew: Bool
}

enum PendingSpanAction {
    case save(EKEvent, EventSnapshot?)
    case delete(EKEvent)
}

struct AvailabilitySlot: Identifiable, Equatable {
    let id = UUID()
    var start: Date
    var end: Date
}

/// Live horizontal pan offset for the time grid. Kept out of AppState so
/// per-frame scroll updates only re-render the three paged strips, not every
/// view observing AppState.
@MainActor
final class PanModel: ObservableObject {
    @Published var offset: CGFloat = 0
}

@MainActor
final class AppState: ObservableObject {
    @Published var currentDate = Date()
    @Published var viewMode: ViewMode = .week {
        didSet { if viewMode != oldValue { gridAnchor = nil } }
    }
    /// Set when navigation (not scrolling) moves the month view; the view scrolls there and clears it.
    @Published var monthScrollTarget: Date?
    /// When set, the time grid starts at this day instead of the aligned week
    /// (free side-scrolling can rest on any day).
    @Published var gridAnchor: Date?
    /// Live horizontal pan offset for the time grid (trackpad side-scroll).
    let pan = PanModel()
    /// Layout metrics reported by the time grid, used for pan re-anchoring.
    var weekPageWidth: CGFloat = 0
    var gridColumnWidth: CGFloat = 0
    /// True while a side-scroll gesture (or its settling animation) is active.
    var isPanning = false
    /// Bumped by navigation (Today, go-to-date) so an in-flight pan gesture or
    /// its momentum stops re-anchoring the grid it just navigated away from.
    var panSession = 0
    /// True while a pinch-zoom gesture is active (suppresses pan capture).
    var isZooming = false
    /// Time-grid vertical scroll metrics (plain vars: written every scroll
    /// frame, must not invalidate views).
    var gridScrollY: CGFloat = 0
    var gridViewportH: CGFloat = 0
    /// Day range highlighted while drag-creating an all-day event in month view.
    @Published var monthDragRange: ClosedRange<Date>?
    /// Transient status message.
    @Published var toast: String?
    /// Time-grid vertical zoom (points per hour), pinch-adjustable.
    @Published var hourHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(hourHeight), forKey: "hourHeight") }
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: "hourHeight")
        hourHeight = stored >= 28 && stored <= 160 ? CGFloat(stored) : 56
    }
    @Published var panelContext: EditorContext?
    @Published var pendingSpanAction: PendingSpanAction?
    @Published var showSpanDialog = false
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// iPhone: presents the calendar list (sidebar equivalent) as a sheet.
    @Published var showCalendarsSheet = false

    // ⌘K palette
    @Published var paletteOpen = false
    let palette = PaletteModel()

    // Availability sharing
    @Published var availabilityMode = false
    @Published var availabilitySlots: [AvailabilitySlot] = []

    let settings = AppSettings.shared

    var calendar: Calendar {
        var c = Calendar.autoupdatingCurrent
        if settings.firstWeekday > 0 { c.firstWeekday = settings.firstWeekday }
        return c
    }

    var visibleDays: [Date] {
        if let anchor = gridAnchor {
            let cal = calendar
            let count: Int
            switch viewMode {
            case .day: count = 1
            case .days(let n): count = n
            case .week: count = 7
            case .month, .year: return []
            }
            return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: anchor) }
        }
        return days(reference: currentDate)
    }

    /// The day columns one page before/after the current ones (for side-scroll).
    func visibleDays(pageOffset: Int) -> [Date] {
        let current = visibleDays
        guard pageOffset != 0 else { return current }
        guard let firstDay = current.first else { return [] }
        let cal = calendar
        if case .week = viewMode, !settings.showWeekends, gridAnchor == nil {
            guard let ref = cal.date(byAdding: .weekOfYear, value: pageOffset, to: firstDay) else { return [] }
            return days(reference: ref)
        }
        guard let start = cal.date(byAdding: .day, value: pageOffset * current.count, to: firstDay) else { return [] }
        return (0..<current.count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Shift the free-scroll anchor by whole days (during trackpad panning).
    func panShiftDays(_ dayDelta: Int) {
        let cal = calendar
        let anchor = gridAnchor ?? visibleDays.first ?? currentDate
        let shifted = cal.date(byAdding: .day, value: dayDelta, to: anchor) ?? anchor
        gridAnchor = shifted
        currentDate = shifted
    }

    private func days(reference: Date) -> [Date] {
        let cal = calendar
        switch viewMode {
        case .day:
            return [reference]
        case .days(let n):
            return (0..<n).compactMap { cal.date(byAdding: .day, value: $0, to: reference) }
        case .week:
            let days = cal.week(containing: reference)
            if settings.showWeekends { return days }
            return days.filter { !cal.isDateInWeekend($0) }
        case .month, .year:
            return []
        }
    }

    // MARK: - Navigation

    func goToToday() { goTo(Date()) }

    func goTo(_ date: Date) {
        cancelPan()
        gridAnchor = nil
        currentDate = date
        monthScrollTarget = date
    }

    /// Abort any in-flight side-scroll (gesture or momentum) before navigating.
    func cancelPan() {
        panSession += 1
        isPanning = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { pan.offset = 0 }
    }

    func step(_ direction: Int) {
        let cal = calendar
        if gridAnchor != nil {
            switch viewMode {
            case .day: panShiftDays(direction)
            case .days(let n): panShiftDays(direction * n)
            case .week: panShiftDays(direction * 7)
            default: break
            }
            return
        }
        switch viewMode {
        case .day:
            currentDate = cal.date(byAdding: .day, value: direction, to: currentDate) ?? currentDate
        case .days(let n):
            currentDate = cal.date(byAdding: .day, value: direction * n, to: currentDate) ?? currentDate
        case .week:
            currentDate = cal.date(byAdding: .weekOfYear, value: direction, to: currentDate) ?? currentDate
        case .month:
            currentDate = cal.date(byAdding: .month, value: direction, to: currentDate) ?? currentDate
            monthScrollTarget = currentDate
        case .year:
            currentDate = cal.date(byAdding: .year, value: direction, to: currentDate) ?? currentDate
        }
    }

    func setDayCount(_ n: Int) {
        gridAnchor = nil
        switch n {
        case 1: viewMode = .day
        case 7: viewMode = .week
        default: viewMode = .days(n)
        }
    }

    // MARK: - Events

    func newEvent(store: CalendarStore, start: Date? = nil, end: Date? = nil, allDay: Bool = false, title: String? = nil) {
        guard store.accessState == .granted else { return }
        let event = EKEvent(eventStore: store.eventStore)
        let startDate = start ?? defaultStart
        event.startDate = startDate
        event.endDate = end ?? startDate.addingTimeInterval(Double(settings.defaultDuration) * 60)
        event.isAllDay = allDay
        event.calendar = store.defaultCalendar
        if let title { event.title = title }
        panelContext = EditorContext(event: event, isNew: true)
    }

    func select(_ event: EKEvent) {
        panelContext = EditorContext(event: event, isNew: false)
    }

    func closePanel() {
        panelContext = nil
    }

    var selectedKey: String? {
        guard let ctx = panelContext, !ctx.isNew else { return nil }
        return eventKey(ctx.event)
    }

    /// Route a change through the recurring-event span dialog when needed.
    func commitChange(to event: EKEvent, snapshot: EventSnapshot?, isNew: Bool, store: CalendarStore) {
        if !isNew, event.hasRecurrenceRules || event.isDetached {
            pendingSpanAction = .save(event, snapshot)
            showSpanDialog = true
        } else {
            store.saveWithUndo(event, snapshot: snapshot, isNew: isNew, span: .thisEvent)
        }
    }

    func requestDelete(_ event: EKEvent, store: CalendarStore) {
        if event.hasRecurrenceRules || event.isDetached {
            pendingSpanAction = .delete(event)
            showSpanDialog = true
        } else {
            store.deleteWithUndo(event, span: .thisEvent)
            if selectedKey == eventKey(event) || panelContext?.event === event { panelContext = nil }
        }
    }

    func resolveSpanAction(span: EKSpan?, store: CalendarStore) {
        defer {
            pendingSpanAction = nil
            showSpanDialog = false
        }
        guard let action = pendingSpanAction else { return }
        guard let span else {
            store.reload() // cancel: discard in-memory changes
            return
        }
        switch action {
        case .save(let event, let snapshot):
            store.saveWithUndo(event, snapshot: snapshot, isNew: false, span: span)
        case .delete(let event):
            store.deleteWithUndo(event, span: span)
            panelContext = nil
        }
    }

    // MARK: - Availability

    func toggleAvailabilityMode() {
        availabilityMode.toggle()
        if !availabilityMode { availabilitySlots.removeAll() }
    }

    func availabilityText() -> String {
        let sorted = availabilitySlots.sorted { $0.start < $1.start }
        let dayFmt = DateFormatter()
        dayFmt.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let interval = DateIntervalFormatter()
        interval.dateStyle = .none
        interval.timeStyle = .short
        let cal = calendar
        var lines: [String] = []
        let grouped = Dictionary(grouping: sorted) { cal.startOfDay(for: $0.start) }
        for day in grouped.keys.sorted() {
            let ranges = grouped[day]!
                .map { interval.string(from: $0.start, to: $0.end) }
                .joined(separator: ", ")
            lines.append("• \(dayFmt.string(from: day)): \(ranges)")
        }
        let tz = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
        return "Would any of these times work? (times in \(tz))\n" + lines.joined(separator: "\n")
    }

    // MARK: - Escape / palette

    func handleEscape() {
        if paletteOpen {
            paletteOpen = false
        } else if panelContext != nil {
            if panelContext?.isNew == false { panelContext = nil } else { panelContext = nil }
        } else if availabilityMode {
            toggleAvailabilityMode()
        }
    }

    private var defaultStart: Date {
        let cal = calendar
        var comps = cal.dateComponents([.year, .month, .day], from: currentDate)
        comps.hour = min(cal.component(.hour, from: Date()) + 1, 23)
        return cal.date(from: comps) ?? currentDate
    }
}

func eventKey(_ event: EKEvent) -> String {
    (event.eventIdentifier ?? "new") + "-" + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0)
}
