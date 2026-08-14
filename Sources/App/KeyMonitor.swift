#if os(macOS)
import AppKit
import SwiftUI

/// Notion-Calendar-style single-key shortcuts (T/D/W/M/C/S, 1–9, arrows, Esc,
/// Delete, Enter) plus ⌘Z routing. Keys pass through untouched while a text
/// field is being edited, except palette navigation keys.
@MainActor
enum KeyMonitor {
    private static var monitor: Any?
    private static var scrollMonitor: Any?
    private static var snapWork: DispatchWorkItem?

    static func install(appState: AppState, store: CalendarStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event, appState: appState, store: store) ? nil : event
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                handleScroll(event, appState: appState) ? nil : event
            }
        }
    }

    // MARK: - Horizontal pan (smooth day-granular side-scroll)

    private static func handleScroll(_ event: NSEvent, appState: AppState) -> Bool {
        switch appState.viewMode {
        case .day, .week, .days: break
        default: return false
        }
        guard !appState.paletteOpen else { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // Once panning, keep capturing even if a sample is vertical-dominant
        let panning = appState.isPanning
        guard abs(dx) > abs(dy) || (panning && abs(dx) > 0.01) else { return false }
        let colWidth = appState.gridColumnWidth
        guard colWidth > 4 else { return false }
        if event.momentumPhase != [] {
            // Let momentum glide keep panning, day by day
            guard panning else { return false }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                settlePan(appState)
                return true
            }
        }
        appState.isPanning = true
        var pan = appState.weekPan + dx
        // Re-anchor a whole page at a time (the strip is 5 pages wide), so
        // expensive re-renders happen once per page instead of once per day
        let pageWidth = appState.weekPageWidth
        let dayCount = max(1, appState.visibleDays.count)
        if pageWidth > 0 {
            while pan <= -pageWidth {
                appState.panShiftDays(dayCount)
                pan += pageWidth
            }
            while pan >= pageWidth {
                appState.panShiftDays(-dayCount)
                pan -= pageWidth
            }
        }
        appState.weekPan = pan
        snapWork?.cancel()
        if event.phase == .ended || event.phase == .cancelled {
            // Trackpad fingers lifted; momentum may still arrive — settle after a beat
            scheduleSettle(appState, delay: 0.08)
        } else if event.phase == [] && event.momentumPhase == [] {
            // Classic scroll wheel: no phases at all
            scheduleSettle(appState, delay: 0.25)
        }
        return true
    }

    private static func scheduleSettle(_ appState: AppState, delay: TimeInterval) {
        snapWork?.cancel()
        let work = DispatchWorkItem { settlePan(appState) }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Settle on a day boundary, with a light extra snap when the frame is
    /// within one day of a full week alignment.
    private static func settlePan(_ appState: AppState) {
        snapWork?.cancel()
        let colWidth = appState.gridColumnWidth
        guard colWidth > 4 else {
            appState.weekPan = 0
            appState.isPanning = false
            return
        }
        var pan = appState.weekPan
        // Nearest day boundary
        let dayShift = Int((-pan / colWidth).rounded())
        if dayShift != 0 {
            appState.panShiftDays(dayShift)
            pan += CGFloat(dayShift) * colWidth
        }
        // Light week snap (week view only): within one day of Sun–Sat framing
        if case .week = appState.viewMode, let anchor = appState.gridAnchor {
            let cal = appState.calendar
            let weekStart = cal.startOfWeek(for: anchor)
            let offsetDays = cal.dateComponents([.day], from: weekStart, to: anchor).day ?? 0
            if offsetDays == 1 {
                appState.panShiftDays(-1)
                pan -= colWidth
            } else if offsetDays == 6 {
                appState.panShiftDays(1)
                pan += colWidth
            }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { appState.weekPan = pan }
        withAnimation(.easeOut(duration: 0.2)) { appState.weekPan = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            appState.isPanning = false
        }
    }

    private static func handle(_ event: NSEvent, appState: AppState, store: CalendarStore) -> Bool {
        let isTyping = NSApp.keyWindow?.firstResponder is NSTextView
            || NSApp.keyWindow?.firstResponder is NSTextField

        // Palette navigation works even while its text field is focused
        if appState.paletteOpen {
            switch event.keyCode {
            case 125: appState.palette.move(1); return true    // down
            case 126: appState.palette.move(-1); return true   // up
            case 36, 76: appState.palette.confirmTick += 1; return true // return
            case 53: appState.paletteOpen = false; return true // esc
            default: return false
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘Z → app undo, but only when not editing text
        if flags == .command, event.charactersIgnoringModifiers == "z" {
            if isTyping { return false }
            store.undo()
            return true
        }
        guard flags.isEmpty || flags == .numericPad || flags == .function || flags == [.numericPad, .function] else { return false }

        // Esc works even while typing (cancel panel / availability)
        if event.keyCode == 53 {
            if isTyping, appState.panelContext == nil { return false }
            appState.handleEscape()
            return true
        }
        if isTyping { return false }

        switch event.keyCode {
        case 123: appState.step(-1); return true  // left
        case 124: appState.step(1); return true   // right
        case 51, 117:                              // delete / fwd delete
            if let ctx = appState.panelContext, !ctx.isNew {
                appState.requestDelete(ctx.event, store: store)
                return true
            }
            return false
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": appState.goToToday(); return true
        case "d": appState.viewMode = .day; return true
        case "w": appState.viewMode = .week; return true
        case "m": appState.viewMode = .month; return true
        case "y": appState.viewMode = .year; return true
        case "c": appState.newEvent(store: store); return true
        case "s": appState.toggleAvailabilityMode(); return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(event.charactersIgnoringModifiers ?? "") {
                appState.setDayCount(n)
                return true
            }
            return false
        default:
            return false
        }
    }
}
#endif
