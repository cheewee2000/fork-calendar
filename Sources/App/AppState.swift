import SwiftUI

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

    /// Which screen this mode renders. Modes in the same family (all the
    /// time-grid variants) animate internally by adding/removing columns;
    /// crossing families plays the row-band zoom. Raw value = zoom depth.
    var zoomFamily: ZoomFamily {
        switch self {
        case .month: return .month
        case .year: return .year
        default: return .grid
        }
    }
}

enum ZoomFamily: Int, Hashable {
    case year = 0, month = 1, grid = 2
}

/// Geometry for one cross-family zoom. Every view is a stack of week rows
/// (time grid = 1 row, month ≈ 6 on screen, year ≈ 53), so the deeper view
/// always occupies a horizontal band of rows inside the shallower one:
/// zooming scales between full height and that band, anchored where the band
/// sits, which reads as rows sliding in/out above and below it.
struct ZoomSpec: Equatable {
    /// band: whole-view fold through the shared week-row band (year pairs).
    /// gridMonth: no view transform at all — both views stay mounted and the
    /// grid's hour section folds/unfolds while its header strip stays put.
    enum Kind { case band, gridMonth }
    var direction: Int      // +1 zooming in (toward day), -1 out, 0 none
    var anchorY: CGFloat    // viewport fraction of the band's center
    var scale: CGFloat      // shallow rows / band rows (stretch factor)
    var kind: Kind = .band
}

struct EditorContext: Identifiable {
    let id = UUID()
    let event: CalEvent
    let isNew: Bool
}

enum PendingSpanAction {
    case save(CalEvent, EventSnapshot?)
    case delete(CalEvent)
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
    /// Geometry of the last cross-family view change. Published so the
    /// outgoing view re-renders with the right transition before the swap
    /// (SwiftUI captures removal transitions one render early).
    @Published var zoomSpec = ZoomSpec(direction: 0, anchorY: 0.5, scale: 1)
    /// True when the month sheet is in place covering the hour grid; false
    /// when it's pushed down below it (week side). Animated during grid↔month.
    @Published var monthCover = false
    /// Bottom edge (in calendar-body coordinates) of the shared week strip,
    /// measured by the grid. The month sheet is masked above this line while
    /// it slides, so the pinned strip is the only copy of the week visible.
    var stripBottomY: CGFloat = 130
    /// True while a grid↔month zoom is in flight: both views stay mounted so
    /// the header strip and month rows are live the whole time — nothing is
    /// destroyed until the fold finishes.
    @Published var gridMonthOverlap = false
    /// Columns the overlapping grid shows once viewMode is already .month
    /// (visibleDays is empty then).
    var gridOverlapDays: [Date] = []
    private var overlapGeneration = 0
    /// False while a zoom/column animation runs: the grid's offscreen
    /// neighbor pages render as empty space so mount commits and per-frame
    /// layout only pay for the visible page.
    @Published var gridNeighborsLive = true
    private var neighborsGeneration = 0

    /// Park the neighbor pages for the duration of an animation, then bring
    /// them back in a non-animated commit once the motion is over.
    private func hideGridNeighbors(restoreAfter delay: Double) {
        neighborsGeneration += 1
        let gen = neighborsGeneration
        gridNeighborsLive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.neighborsGeneration == gen else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.gridNeighborsLive = true }
        }
    }

    /// Change the view mode with an Apple Calendar-style zoom. All mode
    /// switches should go through here (not `viewMode =`) so the transition
    /// knows whether it's diving in or pulling out, and from where.
    func setViewMode(_ mode: ViewMode) {
        if mode == viewMode {
            // Cancels any scheduled cover/cleanup phase (viewMode swaps to
            // .month only at cleanup, so a mid-transition re-press of the
            // current mode lands here — including during the align phase,
            // before the sheet is up).
            overlapGeneration += 1
            if gridMonthOverlap {
                // Sheet is up (or rising): slide it back down.
                let gen = overlapGeneration
                withAnimation(Self.zoomAnimation) { monthCover = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard self.overlapGeneration == gen else { return }
                    self.gridMonthOverlap = false
                }
            } else if gridAnchor != nil {
                // Re-selecting the current grid mode re-aligns a free-anchored
                // view (e.g. 'w' in a side-scrolled week slides Sunday to the
                // left) — animated, never a snap.
                withAnimation(Self.zoomAnimation) { gridAnchor = nil }
            }
            return
        }
        // Cancel any pending phase of an in-flight switch, and drop a stale
        // overlap so a leftover layer never survives into the next mode.
        overlapGeneration += 1
        gridMonthOverlap = false
        if mode.zoomFamily == viewMode.zoomFamily {
            // Same screen (time-grid day-count change): no view swap — the
            // grid animates its own columns in and out. When growing, pin the
            // leftmost visible day so week is just "7 days from here", not a
            // jump to the aligned week start; when shrinking, the default
            // re-anchor to currentDate keeps the shared columns in both sets.
            let oldDays = visibleDays
            let newCount: Int
            switch mode {
            case .day: newCount = 1
            case .days(let n): newCount = n
            default: newCount = 7
            }
            let grownAnchor = newCount >= oldDays.count ? oldDays.first : nil
            // Neighbors stay LIVE here: added columns animate into place
            // precisely because they already exist as neighbor-page columns.
            withAnimation(Self.zoomAnimation) {
                viewMode = mode // didSet clears gridAnchor
                // Anchored weeks bypass the weekend filter, so respect the
                // classic aligned framing when weekends are hidden.
                if let grownAnchor, settings.showWeekends || mode != .week {
                    gridAnchor = grownAnchor
                }
            }
            return
        }
        let fromF = viewMode.zoomFamily, toF = mode.zoomFamily
        if fromF == .grid, toF == .month {
            // Phase 1: if the grid isn't the aligned week (fewer days, or a
            // free anchor), first become it — columns slide and grow so the
            // strip matches the month's top row exactly. Phase 2: the month
            // sheet slides up from below, covering the hours.
            //
            // Nothing heavy may land in a commit that starts visible motion:
            // the keypress commit only starts the align; the sheet (8 light
            // rows) mounts as the align settles; the real MonthView mounts at
            // cleanup, AFTER motion ends — a static pixel-identical swap.
            // viewMode stays .week until that cleanup.
            var aligned = false
            if case .week = viewMode, gridAnchor == nil { aligned = true }
            zoomSpec = ZoomSpec(direction: 0, anchorY: 0, scale: 1, kind: .gridMonth)
            // Pin the month's opening scroll to the week being viewed,
            // overriding any stale target (e.g. a "Today" pressed back in
            // grid mode) so strip, sheet, and settled month agree.
            monthScrollTarget = currentDate
            let gen = overlapGeneration
            let cover: () -> Void = {
                guard self.overlapGeneration == gen else { return }
                self.monthCover = false
                self.gridMonthOverlap = true
                // The sheet mounts in this commit; animating it must wait
                // one runloop turn or it renders directly at the end state.
                DispatchQueue.main.async {
                    guard self.overlapGeneration == gen else { return }
                    withAnimation(Self.zoomAnimation) { self.monthCover = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard self.overlapGeneration == gen else { return }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        self.viewMode = mode
                        self.gridMonthOverlap = false
                    }
                }
            }
            if aligned {
                cover()
            } else {
                withAnimation(Self.zoomAnimation) {
                    viewMode = .week
                    // Explicit: a same-value `.week` assignment skips didSet,
                    // so a free-anchored week would otherwise never re-align.
                    gridAnchor = nil
                }
                // Fixed handoff, timed to the align's settle (easeOut ends
                // hard at its duration): completion-chaining on
                // .logicallyComplete left a dead beat after motion became
                // imperceptible. Deterministic now that the align starts in
                // a light commit at frame one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { cover() }
            }
            return
        }
        if fromF == .month, toF == .grid {
            zoomSpec = ZoomSpec(direction: 0, anchorY: 0, scale: 1, kind: .gridMonth)
            // The grid mounts fresh in this commit — neighbors parked so the
            // commit stays light enough to not stall the slide's first frames.
            hideGridNeighbors(restoreAfter: 0.5)
            monthCover = true // sheet starts up, covering; slides down to reveal
            gridMonthOverlap = true
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { viewMode = mode }
            let gen = overlapGeneration
            DispatchQueue.main.async {
                guard self.overlapGeneration == gen else { return }
                withAnimation(Self.zoomAnimation) { self.monthCover = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard self.overlapGeneration == gen else { return }
                self.gridMonthOverlap = false
            }
            return
        }
        if toF == .grid { hideGridNeighbors(restoreAfter: 0.6) }
        let spec = makeZoomSpec(from: fromF, to: toF)
        if spec != zoomSpec {
            // Publish the spec first, then swap modes on the next runloop
            // turn so the outgoing view's removal transition picks it up.
            zoomSpec = spec
            DispatchQueue.main.async {
                withAnimation(Self.zoomAnimation) { self.viewMode = mode }
            }
        } else {
            withAnimation(Self.zoomAnimation) { viewMode = mode }
        }
    }

    // Ease-out, not a critically-damped spring: the spring started at zero
    // velocity (mushy ramp-in) and crawled through an asymptotic tail (mushy
    // end). Ease-out moves at full speed on frame one and stops decisively.
    static let zoomAnimation = Animation.easeOut(duration: 0.28)

    private func makeZoomSpec(from: ZoomFamily, to: ZoomFamily) -> ZoomSpec {
        let zoomingIn = to.rawValue > from.rawValue
        let shallow = zoomingIn ? from : to
        let deep = zoomingIn ? to : from
        let cal = calendar
        let viewportH = gridViewportH > 100 ? gridViewportH : 700
        // MonthView shows viewport/rowHeight(108) week rows, current week at top.
        let monthVisibleRows = max(viewportH / 108, 2)

        var total: CGFloat = 1, bandStart: CGFloat = 0, band: CGFloat = 1
        let week = cal.startOfWeek(for: currentDate)
        switch shallow {
        case .month:
            // Month scrolls the current week to the top of its viewport.
            total = monthVisibleRows
            bandStart = 0
            band = 1
        case .year:
            let year = cal.component(.year, from: currentDate)
            if let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
               let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31)) {
                let firstWeek = cal.startOfWeek(for: jan1)
                let lastWeek = cal.startOfWeek(for: dec31)
                total = CGFloat((cal.dateComponents([.day], from: firstWeek, to: lastWeek).day ?? 358) / 7 + 1)
                bandStart = CGFloat((cal.dateComponents([.day], from: firstWeek, to: week).day ?? 0) / 7)
                band = deep == .month ? min(monthVisibleRows, total - bandStart) : 1
            }
        case .grid:
            break // grid is never the shallow side
        }
        let anchorY = min(max((bandStart + band / 2) / total, 0), 1)
        return ZoomSpec(direction: zoomingIn ? 1 : -1,
                        anchorY: anchorY,
                        scale: max(total / max(band, 0.5), 1))
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
    /// iOS: settings/accounts sheet (macOS uses the Settings window).
    @Published var showSettingsSheet = false

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
    /// The grid passes its own `current` columns so that a grid mid-removal
    /// (zoom to month/year, when `visibleDays` is already empty) keeps a
    /// stable layout instead of collapsing while it animates out.
    func visibleDays(pageOffset: Int, current currentOverride: [Date]? = nil) -> [Date] {
        let current = currentOverride ?? visibleDays
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

    /// Jump to today. In multi-day grids, frame today as the second column
    /// (one day of context before it) instead of the calendar-week start.
    func goToToday() {
        let today = Date()
        switch viewMode {
        case .days, .week:
            // Anchored framing shows consecutive days; with weekends hidden
            // that would surface them, so keep classic week framing there.
            if case .week = viewMode, !settings.showWeekends {
                goTo(today)
                return
            }
            cancelPan()
            let cal = calendar
            gridAnchor = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: today))
            currentDate = today
            monthScrollTarget = today
        default:
            goTo(today)
        }
    }

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
        // No unanimated gridAnchor clear here: setViewMode animates the
        // re-align (an instant clear snapped an anchored week to Sunday-left,
        // which also made the later week→month align look like it never ran).
        switch n {
        case 1: setViewMode(.day)
        case 7: setViewMode(.week)
        default: setViewMode(.days(n))
        }
    }

    // MARK: - Events

    func newEvent(store: CalendarStore, start: Date? = nil, end: Date? = nil, allDay: Bool = false, title: String? = nil) {
        guard store.accessState == .granted else { return }
        let event = store.newEvent()
        let startDate = start ?? defaultStart
        event.startDate = startDate
        event.endDate = end ?? startDate.addingTimeInterval(Double(settings.defaultDuration) * 60)
        event.isAllDay = allDay
        if let title { event.title = title }
        panelContext = EditorContext(event: event, isNew: true)
    }

    func select(_ event: CalEvent) {
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
    func commitChange(to event: CalEvent, snapshot: EventSnapshot?, isNew: Bool, store: CalendarStore) {
        if !isNew, event.isInstance {
            pendingSpanAction = .save(event, snapshot)
            showSpanDialog = true
        } else {
            store.saveWithUndo(event, snapshot: snapshot, isNew: isNew, span: .thisEvent)
        }
    }

    func requestDelete(_ event: CalEvent, store: CalendarStore) {
        if event.isInstance {
            pendingSpanAction = .delete(event)
            showSpanDialog = true
        } else {
            store.deleteWithUndo(event, span: .thisEvent)
            if selectedKey == eventKey(event) || panelContext?.event === event { panelContext = nil }
        }
    }

    func resolveSpanAction(span: EditSpan?, store: CalendarStore) {
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

func eventKey(_ event: CalEvent) -> String {
    (event.eventIdentifier ?? "new") + "-" + String(event.startDate?.timeIntervalSinceReferenceDate ?? 0)
}
