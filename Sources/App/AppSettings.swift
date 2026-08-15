import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 0 = system, 1 = Sunday, 2 = Monday (Calendar.firstWeekday convention)
    @Published var firstWeekday: Int { didSet { UserDefaults.standard.set(firstWeekday, forKey: "firstWeekday") } }
    /// Minutes
    @Published var defaultDuration: Int { didSet { UserDefaults.standard.set(defaultDuration, forKey: "defaultDuration") } }
    @Published var showDeclined: Bool {
        didSet {
            UserDefaults.standard.set(showDeclined, forKey: "showDeclined")
            WidgetBridge.mirror(showDeclined: showDeclined)
        }
    }
    @Published var showWeekends: Bool { didSet { UserDefaults.standard.set(showWeekends, forKey: "showWeekends") } }
    /// Month view: hide timed-event chips, keep only all-day/multi-day bars
    @Published var monthAllDayOnly: Bool { didSet { UserDefaults.standard.set(monthAllDayOnly, forKey: "monthAllDayOnly") } }
    /// Extra time-zone columns in the time gutter (TimeZone identifiers, in order)
    @Published var secondaryTZs: [String] { didSet { UserDefaults.standard.set(secondaryTZs, forKey: "secondaryTZs") } }
    /// Personal Zoom meeting URL, used by "Add conferencing"
    @Published var zoomLink: String { didSet { UserDefaults.standard.set(zoomLink, forKey: "zoomLink") } }
    /// Per-calendar color overrides (calendarIdentifier → hex "RRGGBB")
    @Published var calendarColors: [String: String] {
        didSet {
            UserDefaults.standard.set(calendarColors, forKey: "calendarColors")
            WidgetBridge.mirror(calendarColors: calendarColors)
        }
    }
    /// Google OAuth desktop-app client (user-supplied, from console.cloud.google.com)
    @Published var googleClientID: String { didSet { UserDefaults.standard.set(googleClientID, forKey: "googleClientID") } }
    @Published var googleClientSecret: String { didSet { UserDefaults.standard.set(googleClientSecret, forKey: "googleClientSecret") } }

    private init() {
        let d = UserDefaults.standard
        firstWeekday = d.integer(forKey: "firstWeekday")
        defaultDuration = d.object(forKey: "defaultDuration") as? Int ?? 60
        showDeclined = d.object(forKey: "showDeclined") as? Bool ?? true
        showWeekends = d.object(forKey: "showWeekends") as? Bool ?? true
        monthAllDayOnly = d.object(forKey: "monthAllDayOnly") as? Bool ?? false
        if let list = d.stringArray(forKey: "secondaryTZs") {
            secondaryTZs = list
        } else if let legacy = d.string(forKey: "secondaryTZ"), !legacy.isEmpty {
            secondaryTZs = [legacy] // migrate the old single-zone setting
        } else {
            secondaryTZs = []
        }
        zoomLink = d.string(forKey: "zoomLink") ?? ""
        calendarColors = d.dictionary(forKey: "calendarColors") as? [String: String] ?? [:]
        googleClientID = d.string(forKey: "googleClientID") ?? ""
        googleClientSecret = d.string(forKey: "googleClientSecret") ?? ""
    }

    var secondaryTimeZones: [TimeZone] {
        secondaryTZs.compactMap(TimeZone.init(identifier:))
    }

    static let curatedTimeZones: [String] = [
        "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
        "America/Sao_Paulo", "Europe/London", "Europe/Paris", "Europe/Berlin",
        "Europe/Madrid", "Africa/Cairo", "Asia/Dubai", "Asia/Kolkata",
        "Asia/Shanghai", "Asia/Tokyo", "Asia/Seoul", "Asia/Singapore",
        "Australia/Sydney", "Pacific/Auckland", "UTC",
    ]

    static func timeZoneLabel(_ id: String) -> String {
        (id.components(separatedBy: "/").last ?? id).replacingOccurrences(of: "_", with: " ")
    }
}
