import SwiftUI
import Combine

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

    /// Stable UserDefaults form, so the app reopens in the mode it quit in.
    var saveKey: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .days(let n): return "days:\(n)"
        case .month: return "month"
        case .year: return "year"
        }
    }

    init?(saveKey: String?) {
        switch saveKey {
        case "day": self = .day
        case "week": self = .week
        case "month": self = .month
        case "year": self = .year
        default:
            guard let saveKey, saveKey.hasPrefix("days:"),
                  let n = Int(saveKey.dropFirst(5)), (2...14).contains(n)
            else { return nil }
            self = .days(n)
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
    let event: CalEvent
    let isNew: Bool
    /// Keyed on the event, not a UUID: reresolveSelection swaps in a fresh
    /// CalEvent after every store reload, and a fresh id made .sheet(item:)
    /// dismiss + re-present on each sync tick (iPhone sheet flickered 3×).
    var id: String { (isNew ? "new-" : "") + eventKey(event) }
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

/// @Observable, not ObservableObject: views re-render only for the properties
/// they read. As an ObservableObject every property change synchronously
/// re-rendered every observing view (each day cell, event block, year cell),
/// several times per view-mode switch — 0.5–1.2s main-thread stalls that ate
/// the whole zoom animation. Plain bookkeeping vars are @ObservationIgnored.
@MainActor
@Observable
final class AppState {
    var currentDate = Date() {
        didSet { scheduleParkedMonthSync() }
    }
    var viewMode: ViewMode = ViewMode(saveKey: UserDefaults.standard.string(forKey: "lastViewMode")) ?? .week {
        didSet {
            if viewMode != oldValue { gridAnchor = nil }
            UserDefaults.standard.set(viewMode.saveKey, forKey: "lastViewMode")
        }
    }
    /// Geometry of the last cross-family view change. Published so the
    /// outgoing view re-renders with the right transition before the swap
    /// (SwiftUI captures removal transitions one render early).
    var zoomSpec = ZoomSpec(direction: 0, anchorY: 0.5, scale: 1)
    /// True when the month sheet is in place covering the hour grid; false
    /// when it's pushed down below it (week side). Animated during grid↔month.
    var monthCover = false
    /// Bottom edge (in calendar-body coordinates) of the shared week strip,
    /// measured by the grid. The month sheet is masked above this line while
    /// it slides, so the pinned strip is the only copy of the week visible.
    @ObservationIgnored var stripBottomY: CGFloat = 130
    /// True while a grid↔month zoom is in flight: both views stay mounted so
    /// the header strip and month rows are live the whole time — nothing is
    /// destroyed until the fold finishes.
    var gridMonthOverlap = false
    @ObservationIgnored private var overlapGeneration = 0
    /// Keep-alive across week↔month. Building either view from scratch is
    /// what a W/M keypress used to wait on (100–250ms before anything moved),
    /// so once both have been shown they stay mounted through the toggle:
    /// in grid modes the MonthView sits parked below the viewport (clipped,
    /// exactly the pre-slide state), and in month mode the grid stays under
    /// the opaque month, frozen on the days it had (`gridParkedDays`).
    /// Cost: a store change re-renders both. Year mode drops both.
    var monthParked = false
    var gridParked = false
    var gridParkedDays: [Date] = []
    @ObservationIgnored private var parkSyncGeneration = 0

    /// Navigating in a grid mode moves the parked month to the viewed week —
    /// shortly after the navigation, not in its commit — so a later M finds
    /// the rows already built. (M itself still syncs if this hasn't run.)
    private func scheduleParkedMonthSync() {
        guard monthParked else { return }
        parkSyncGeneration += 1
        let gen = parkSyncGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.parkSyncGeneration == gen, self.monthParked, !self.gridMonthOverlap,
                  self.viewMode.zoomFamily == .grid else { return }
            self.monthScrollTarget = self.currentDate
        }
    }

    /// False while a zoom/column animation runs: the grid's offscreen
    /// neighbor pages render as empty space so mount commits and per-frame
    /// layout only pay for the visible page.
    var gridNeighborsLive = true
    @ObservationIgnored private var neighborsGeneration = 0
    /// Bumped in the same commit as any column-geometry change that should
    /// animate. The grid scopes its animation to this value
    /// (`.animation(_:value:)`) instead of relying on withAnimation's
    /// transaction: a CalendarStore publish (event sync) landing in the same
    /// update cycle used to strip the transaction and snap the transition.
    var zoomTick = 0

    /// The day at the viewport's left edge as the user actually sees it:
    /// the anchor (or aligned first day) plus the fractional page held in
    /// the resting pan offset — a side-scroll can leave the strip parked
    /// mid-week without ever touching gridAnchor.
    private var visualFirstDay: Date? {
        guard let base = gridAnchor ?? visibleDays.first else { return nil }
        guard gridColumnWidth > 4, abs(pan.offset) > 1 else { return base }
        let dayShift = Int((-pan.offset / gridColumnWidth).rounded())
        return calendar.date(byAdding: .day, value: dayShift, to: base)
    }

    /// Whether the grid is visually resting on its aligned days (Sunday at
    /// the left for week view): no free anchor AND no resting pan offset.
    private var gridVisuallyAligned: Bool {
        gridAnchor == nil && abs(pan.offset) < 1
    }

    /// One animated commit that slides the grid home: re-points currentDate
    /// at the days actually on screen, clears the free anchor AND the
    /// resting pan offset, and bumps zoomTick so it all animates as one move.
    private func realignGrid() {
        if let vf = visualFirstDay,
           let center = calendar.date(byAdding: .day, value: max(visibleDays.count, 1) / 2, to: vf),
           !calendar.isDate(center, inSameDayAs: currentDate) {
            currentDate = center
        }
        gridAnchor = nil
        pan.offset = 0
        zoomTick += 1
    }

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
        finishStepSlide?() // land an in-flight arrow-key slide first
        if mode == viewMode {
            // Cancels any scheduled cover/cleanup phase (viewMode swaps to
            // .month only at cleanup, so a mid-transition re-press of the
            // current mode lands here — including during the align phase,
            // before the sheet is up).
            overlapGeneration += 1
            if gridMonthOverlap {
                // Sheet is up (or rising): slide it back down. (The sheet's
                // own .animation(value: monthCover) drives the motion.)
                let gen = overlapGeneration
                monthCover = false
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseDelay(Self.zoomDuration + 0.02)) {
                    guard self.overlapGeneration == gen else { return }
                    self.gridMonthOverlap = false
                }
            } else if !gridVisuallyAligned {
                // Re-selecting the current grid mode re-aligns a side-scrolled
                // view (e.g. 'w' in a panned week slides Sunday to the left) —
                // animated, never a snap.
                realignGrid()
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
            // Plain mutations + zoomTick: the grid's .animation(value:) scopes
            // the animation to this change, immune to whatever else lands in
            // the same update cycle (withAnimation's transaction wasn't).
            viewMode = mode // didSet clears gridAnchor
            // Anchored weeks bypass the weekend filter, so respect the
            // classic aligned framing when weekends are hidden.
            if let grownAnchor, settings.showWeekends || mode != .week {
                gridAnchor = grownAnchor
            }
            zoomTick += 1
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
            // the keypress commit only starts the align; the MonthView mounts
            // (clipped below the strip, parked under the viewport) as the
            // align settles and slides one runloop later. Cleanup, AFTER
            // motion ends, just drops the clip and the grid — viewMode stays
            // .week until then. ("Sheet" below = that sliding MonthView.)
            // "Aligned" means VISUALLY aligned: a side-scroll parks the strip
            // at a fractional pan offset without touching gridAnchor, so the
            // anchor alone can't tell whether Sunday is at the left.
            var aligned = false
            if case .week = viewMode, gridVisuallyAligned { aligned = true }
            zoomSpec = ZoomSpec(direction: 0, anchorY: 0, scale: 1, kind: .gridMonth)
            // Pin the month's opening scroll to the week being viewed,
            // overriding any stale target (e.g. a "Today" pressed back in
            // grid mode) so strip, sheet, and settled month agree.
            monthScrollTarget = currentDate
            let gen = overlapGeneration
            let cover: () -> Void = {
                guard self.overlapGeneration == gen else { return }
                let alreadyMounted = self.monthParked
                self.monthCover = false
                self.gridMonthOverlap = true
                self.monthParked = true
                let slide = {
                    guard self.overlapGeneration == gen else { return }
                    self.monthCover = true // sheet's .animation(value:) slides it
                    // Cleanup is anchored to the slide's start commit, not the
                    // keypress, so a slow mount can't cut the slide short.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseDelay(Self.zoomDuration + 0.02)) {
                        guard self.overlapGeneration == gen else { return }
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            // The grid stays mounted under the month, frozen
                            // on these days. Parked BEFORE the mode flips so
                            // no evaluation sees month-without-grid and tears
                            // it down.
                            self.gridParkedDays = self.visibleDays
                            self.gridParked = true
                            self.viewMode = mode
                            self.gridMonthOverlap = false
                            self.monthScrollTarget = nil
                        }
                    }
                }
                // A MonthView mounting in this commit must render once at its
                // start position before it can animate; a parked one already
                // has, so it slides in the keypress's own commit.
                if alreadyMounted { slide() } else { DispatchQueue.main.async(execute: slide) }
            }
            if aligned {
                cover()
            } else {
                // Capture the visual position BEFORE the mode swap, then slide
                // home: anchor cleared, resting pan offset zeroed, currentDate
                // re-pointed at the week on screen — one animated move.
                realignGrid()
                viewMode = .week // no-op if already .week; didSet re-clears anchor
                // The sheet waits for the align to finish. The countdown is
                // anchored one runloop later — after the align's commit has
                // rendered — because the align's animation clock starts at its
                // first FRAME, not at the keypress: on a heavy commit a
                // keypress-anchored timer expired early and the sheet rose
                // before the columns had visibly slid.
                DispatchQueue.main.async {
                    guard self.overlapGeneration == gen else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseDelay(Self.zoomDuration)) { cover() }
                }
            }
            return
        }
        if fromF == .month, toF == .grid {
            zoomSpec = ZoomSpec(direction: 0, anchorY: 0, scale: 1, kind: .gridMonth)
            // A grid mounting fresh in this commit parks its neighbor pages
            // so the commit stays light enough to not stall the slide's first
            // frames; one kept alive under the month is already whole.
            if !gridParked { hideGridNeighbors(restoreAfter: 0.5) }
            monthCover = true // starts up, covering; slides down to reveal
            gridMonthOverlap = true
            monthParked = true // the month stays mounted, parked, after the slide
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                viewMode = mode
                // A pan offset left over from before entering month view would
                // mount the revealed grid visually shifted off Sunday.
                pan.offset = 0
            }
            let gen = overlapGeneration
            DispatchQueue.main.async {
                guard self.overlapGeneration == gen else { return }
                self.monthCover = false // sheet's .animation(value:) slides it
                // Anchored to the slide's start commit (see cover-up path).
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseDelay(Self.zoomDuration + 0.02)) {
                    guard self.overlapGeneration == gen else { return }
                    self.gridMonthOverlap = false
                }
            }
            return
        }
        if toF == .grid { hideGridNeighbors(restoreAfter: 0.6) }
        // Year mode keeps nothing alive. Cleared once the zoom is over: the
        // parked view leaves with its visible sibling's transition instead of
        // being torn down in the commit that starts the motion. (Entering
        // from year, the flags are already clear.)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseDelay(Self.zoomDuration + 0.1)) {
            guard self.viewMode.zoomFamily == .year else { return }
            self.monthParked = false
            self.gridParked = false
        }
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

    // Linear, no easing: constant speed from frame one to a hard stop.
    static var zoomAnimation: Animation { .linear(duration: slowZoom ? 2.0 : zoomDuration) }
    /// One zoom/slide phase. Phase handoffs are timed off this same number.
    static let zoomDuration = 0.22
    /// Debug: 8x slow motion for scripted transition recordings ("!" hook key).
    static var slowZoom = false
    /// Phase-handoff delays scale with slow motion so sequencing stays honest.
    static func phaseDelay(_ d: Double) -> Double { slowZoom ? d * 2.0 / zoomDuration : d }

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
    var monthScrollTarget: Date?
    /// When set, the time grid starts at this day instead of the aligned week
    /// (free side-scrolling can rest on any day).
    var gridAnchor: Date?
    /// Live horizontal pan offset for the time grid (trackpad side-scroll).
    let pan = PanModel()
    /// Layout metrics reported by the time grid, used for pan re-anchoring.
    @ObservationIgnored var weekPageWidth: CGFloat = 0
    @ObservationIgnored var gridColumnWidth: CGFloat = 0
    /// True while a side-scroll gesture (or its settling animation) is active.
    @ObservationIgnored var isPanning = false
    /// Bumped by navigation (Today, go-to-date) so an in-flight pan gesture or
    /// its momentum stops re-anchoring the grid it just navigated away from.
    @ObservationIgnored var panSession = 0
    /// True while a pinch-zoom gesture is active (suppresses pan capture).
    @ObservationIgnored var isZooming = false
    /// Time-grid vertical scroll metrics (plain vars: written every scroll
    /// frame, must not invalidate views).
    @ObservationIgnored var gridScrollY: CGFloat = 0
    @ObservationIgnored var gridViewportH: CGFloat = 0
    /// Day range highlighted while drag-creating an all-day event in month view.
    var monthDragRange: ClosedRange<Date>?
    /// Transient status message.
    var toast: String?
    /// Time-grid vertical zoom (points per hour), pinch-adjustable.
    var hourHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(hourHeight), forKey: "hourHeight") }
    }

    init() {
        let stored = UserDefaults.standard.double(forKey: "hourHeight")
        hourHeight = stored >= 8 && stored <= 160 ? CGFloat(stored) : 56
        #if os(macOS)
        // Automation hook: lets scripted tests drive view-mode changes
        // (`ForkCalDebugKey` distributed notification with a key string) so
        // transitions can be screen-recorded and verified without a human at
        // the keyboard. Accepts only the KeyMonitor mode keys.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ForkCalDebugKey"), object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.object as? String else { return }
            Task { @MainActor in
                guard let self else { return }
                switch key {
                case "d": self.setViewMode(.day)
                case "w": self.setViewMode(.week)
                case "m": self.setViewMode(.month)
                case "y": self.setViewMode(.year)
                case "t": self.goToToday()
                case "up": self.scrollRows(-1)
                case "down": self.scrollRows(1)
                case "left": self.step(-1)
                case "right": self.step(1)
                case "1"..."9": self.setDayCount(Int(key) ?? 7)
                case "!": Self.slowZoom.toggle()
                case "k": self.paletteOpen = true
                case "esc": self.handleEscape()
                default:
                    // "type:<text>" fills the palette query (opening it first)
                    // so search results can be verified without a keyboard.
                    // "press:<keyCode>:<chars>" queues a real key-down, so it
                    // runs through KeyMonitor like a typed key.
                    let parts = key.split(separator: ":", omittingEmptySubsequences: false)
                    if parts.count == 3, parts[0] == "press", let code = UInt16(parts[1]),
                       let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
                       let e = NSEvent.keyEvent(
                           with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, characters: String(parts[2]),
                           charactersIgnoringModifiers: String(parts[2]), isARepeat: false, keyCode: code) {
                        NSApp.postEvent(e, atStart: false)
                    }
                    // "h:<points>" grows/shrinks the main window's height.
                    if key.hasPrefix("h:"), let d = Double(key.dropFirst(2)),
                       let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) {
                        var f = w.frame
                        f.size.height += d
                        w.setFrame(f, display: true)
                    }
                    // "describe:<text>" submits text to an open new-event
                    // panel's describe box.
                    if key.hasPrefix("describe:") { self.debugDescribe = String(key.dropFirst(9)) }
                    if key.hasPrefix("type:") {
                        self.paletteOpen = true
                        // After the palette's open-reset (delivered on the
                        // next main-queue tick), so the query survives it.
                        DispatchQueue.main.async {
                            self.palette.query = String(key.dropFirst(5))
                        }
                    }
                }
            }
        }
        #endif
    }
    var panelContext: EditorContext?
    var pendingSpanAction: PendingSpanAction?
    var showSpanDialog = false
    /// Sidebar shown/hidden survives relaunch, like the view mode.
    var columnVisibility: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: "sidebarHidden") ? .detailOnly : .all {
        didSet {
            UserDefaults.standard.set(columnVisibility == .detailOnly, forKey: "sidebarHidden")
        }
    }
    /// iPhone: presents the calendar list (sidebar equivalent) as a sheet.
    var showCalendarsSheet = false
    /// iOS: settings/accounts sheet (macOS uses the Settings window).
    var showSettingsSheet = false

    // ⌘K palette
    var paletteOpen = false { didSet { paletteOpenChanges.send(paletteOpen) } }
    /// Combine mirror of paletteOpen for the always-mounted palette's
    /// one-time sink (what `$paletteOpen` was under @Published).
    @ObservationIgnored let paletteOpenChanges = CurrentValueSubject<Bool, Never>(false)
    let palette = PaletteModel()

    // Availability sharing
    var availabilityMode = false
    var availabilitySlots: [AvailabilitySlot] = []

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
    /// Shared by the macOS trackpad (KeyMonitor) and iOS touch (SideScrollPan)
    /// pans: shift the strip by dx, re-anchoring a whole page at a time (the
    /// strip is 3 pages wide) so expensive re-renders happen once per page.
    func applyPan(_ dx: CGFloat) {
        var offset = pan.offset + dx
        let pageWidth = weekPageWidth
        let dayCount = max(1, visibleDays.count)
        if pageWidth > 0 {
            while offset <= -pageWidth { panShiftDays(dayCount); offset += pageWidth }
            while offset >= pageWidth { panShiftDays(-dayCount); offset -= pageWidth }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { pan.offset = offset }
    }

    /// End of a pan: columns rest where the gesture left them — layout is
    /// never touched. Only currentDate is re-pointed at the day nearest the
    /// visible left edge (header label, fetch window). isPanning clears after
    /// the currentDate onChange pass unless `stillPanning` says a new gesture
    /// already latched.
    func settlePan(stillPanning: @escaping () -> Bool) {
        if let anchor = gridAnchor, gridColumnWidth > 4 {
            let dayShift = Int((-pan.offset / gridColumnWidth).rounded())
            if dayShift != 0, let visualFirst = calendar.date(byAdding: .day, value: dayShift, to: anchor) {
                currentDate = visualFirst
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if !stillPanning() { self?.isPanning = false }
        }
    }

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
        default:
            goTo(today)
        }
    }

    func goTo(_ date: Date) {
        cancelPan()
        gridAnchor = nil
        currentDate = date
        // In grid modes a parked month follows via scheduleParkedMonthSync;
        // scrolling it in this commit would stall the navigation itself.
        if viewMode == .month { monthScrollTarget = date }
    }

    /// Abort any in-flight side-scroll (gesture or momentum) before navigating.
    func cancelPan() {
        // Navigation elsewhere drops an in-flight arrow-key slide.
        stepGeneration += 1
        finishStepSlide = nil
        panSession += 1
        isPanning = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { pan.offset = 0 }
    }

    /// ↑ / ↓ in month and year views: scroll by rows. Those views own their
    /// scroll position, so this is only a signal they apply (and animate).
    var rowScrollTick = 0
    /// Debug hook → the new-event panel's describe box.
    var debugDescribe = ""
    @ObservationIgnored var rowScrollDelta = 0
    func scrollRows(_ delta: Int) {
        rowScrollDelta = delta
        rowScrollTick += 1
    }

    /// ‹ › / arrow keys. In grid modes the strip slides one page (the
    /// neighbor page is already mounted), then the dates shift under it in a
    /// non-animated commit that is pixel-identical to the slide's end frame.
    func step(_ direction: Int) {
        finishStepSlide?() // a press mid-slide lands the previous one first
        // ponytail: a strip resting at a fractional pan offset (after a
        // trackpad side-scroll) steps instantly, as before — sliding from
        // there can run off the 3-page strip. Re-align first if that matters.
        guard viewMode.zoomFamily == .grid, weekPageWidth > 0, gridNeighborsLive,
              !isPanning, abs(pan.offset) < 1 else {
            commitStep(direction)
            return
        }
        stepGeneration += 1
        let gen = stepGeneration
        pan.offset = -CGFloat(direction) * weekPageWidth
        zoomTick += 1 // the grid's .animation(value:) animates the offset
        let finish = {
            guard self.stepGeneration == gen else { return }
            self.stepGeneration += 1
            self.finishStepSlide = nil
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                self.commitStep(direction)
                self.pan.offset = 0
            }
        }
        finishStepSlide = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseDelay(Self.zoomDuration), execute: finish)
    }
    @ObservationIgnored private var stepGeneration = 0
    @ObservationIgnored private var finishStepSlide: (() -> Void)?

    private func commitStep(_ direction: Int) {
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

    /// ⌘C's event. In-app only; not the system pasteboard.
    @ObservationIgnored var clipboard: EventSnapshot?
    /// Where ⌘V lands: the grid slot (timed) or month day under the pointer.
    /// Plain var — hover updates it on every mouse move, no re-render wanted.
    @ObservationIgnored var pasteTarget: (date: Date, timed: Bool)?

    func copyEvent(_ event: CalEvent? = nil, store: CalendarStore) {
        guard let event = event ?? panelContext.flatMap({ $0.isNew ? nil : $0.event }) else { return }
        clipboard = EventSnapshot(event)
        store.toast = "Copied"
    }

    /// Timed events keep their length; on a day-only target (month cell) they
    /// keep their time of day too. All-day events land on the target's day.
    func pasteEvent(store: CalendarStore) {
        guard var s = clipboard, store.accessState == .granted else { return }
        let length = s.end.timeIntervalSince(s.start)
        let target = pasteTarget ?? (date: defaultStart, timed: true)
        if s.isAllDay || !target.timed {
            let day = calendar.startOfDay(for: target.date)
            let timeOfDay = s.isAllDay ? 0 : s.start.timeIntervalSince(calendar.startOfDay(for: s.start))
            s.start = day.addingTimeInterval(timeOfDay)
        } else {
            s.start = target.date
        }
        s.end = s.start.addingTimeInterval(length)
        store.paste(s)
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

    /// ⌘⌫: delete the selected event — this occurrence only, no span dialog.
    func quickDelete(store: CalendarStore) {
        guard let ctx = panelContext, !ctx.isNew else { return }
        store.deleteWithUndo(ctx.event, span: .thisEvent, notify: false)
        panelContext = nil
    }

    /// B / ⌘B: open the palette listing draft invoices on invoice.cwandt.com
    /// to bill `event` (default: the selected event) to.
    func billEvent(_ event: CalEvent? = nil) {
        guard let event = event ?? panelContext.flatMap({ $0.isNew ? nil : $0.event }) else { return }
        palette.billing = event
        paletteOpen = true
        Task { await InvoiceLink.shared.refresh() }
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
        return lines.joined(separator: "\n")
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
