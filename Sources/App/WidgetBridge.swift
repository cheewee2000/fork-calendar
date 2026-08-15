import Foundation
#if os(iOS)
import WidgetKit
#endif

/// Mirrors the settings the widget needs into the shared app-group container
/// and pokes WidgetKit when data changes. No-op on macOS (no widget there).
enum WidgetBridge {
    static let suiteName = "group.com.cwandt.forkcalendar"

    static func mirror(hiddenCalendarIDs: Set<String>? = nil,
                       calendarColors: [String: String]? = nil,
                       showDeclined: Bool? = nil) {
        #if os(iOS)
        guard let d = UserDefaults(suiteName: suiteName) else { return }
        if let ids = hiddenCalendarIDs { d.set(Array(ids), forKey: "hiddenCalendarIDs") }
        if let colors = calendarColors { d.set(colors, forKey: "calendarColors") }
        if let show = showDeclined { d.set(show, forKey: "showDeclined") }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func reload() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
