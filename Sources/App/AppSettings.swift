import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 0 = system, 1 = Sunday, 2 = Monday (Calendar.firstWeekday convention)
    @Published var firstWeekday: Int { didSet { UserDefaults.standard.set(firstWeekday, forKey: "firstWeekday") } }
    /// Minutes
    @Published var defaultDuration: Int { didSet { UserDefaults.standard.set(defaultDuration, forKey: "defaultDuration") } }
    @Published var showDeclined: Bool { didSet { UserDefaults.standard.set(showDeclined, forKey: "showDeclined") } }
    @Published var showWeekends: Bool { didSet { UserDefaults.standard.set(showWeekends, forKey: "showWeekends") } }
    /// TimeZone identifier, empty = none
    @Published var secondaryTZ: String { didSet { UserDefaults.standard.set(secondaryTZ, forKey: "secondaryTZ") } }

    private init() {
        let d = UserDefaults.standard
        firstWeekday = d.integer(forKey: "firstWeekday")
        defaultDuration = d.object(forKey: "defaultDuration") as? Int ?? 60
        showDeclined = d.object(forKey: "showDeclined") as? Bool ?? true
        showWeekends = d.object(forKey: "showWeekends") as? Bool ?? true
        secondaryTZ = d.string(forKey: "secondaryTZ") ?? ""
    }

    var secondaryTimeZone: TimeZone? {
        secondaryTZ.isEmpty ? nil : TimeZone(identifier: secondaryTZ)
    }
}
