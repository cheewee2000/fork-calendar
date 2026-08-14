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

    // MARK: - Horizontal pan (trackpad side-scroll to neighboring weeks)

    private static func handleScroll(_ event: NSEvent, appState: AppState) -> Bool {
        switch appState.viewMode {
        case .day, .week, .days: break
        default: return false
        }
        guard !appState.paletteOpen else { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // Once panning, keep capturing even if a sample is vertical-dominant
        let panning = appState.weekPan != 0
        guard abs(dx) > abs(dy) || (panning && abs(dx) > 0.01) else { return false }
        if event.momentumPhase != [] {
            return panning // swallow horizontal momentum during/after a pan
        }
        let pageWidth = appState.weekPageWidth
        guard pageWidth > 0 else { return false }
        appState.weekPan = max(-pageWidth, min(pageWidth, appState.weekPan + dx))
        snapWork?.cancel()
        if event.phase == .ended || event.phase == .cancelled {
            snapPan(appState)
        } else {
            // Fallback for classic scroll wheels that never send an .ended phase
            let work = DispatchWorkItem { snapPan(appState) }
            snapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        return true
    }

    private static func snapPan(_ appState: AppState) {
        snapWork?.cancel()
        let pageWidth = appState.weekPageWidth
        let pan = appState.weekPan
        guard pageWidth > 0, pan != 0 else { return }
        if pan < -pageWidth / 4 {
            withAnimation(.easeOut(duration: 0.18)) { appState.weekPan = -pageWidth }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                appState.step(1) // grid resets pan without animation on date change
            }
        } else if pan > pageWidth / 4 {
            withAnimation(.easeOut(duration: 0.18)) { appState.weekPan = pageWidth }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                appState.step(-1)
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { appState.weekPan = 0 }
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
