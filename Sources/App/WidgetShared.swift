import Foundation

/// What the app publishes for the iOS widget (today + next two days),
/// already filtered by hidden calendars / declined setting.
struct WidgetItem: Codable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let colorHex: String
}

enum WidgetData {
    static let suiteName = "group.com.cwandt.forkcalendar"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent("widget-events.json")
    }

    static func read() -> [WidgetItem]? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WidgetItem].self, from: data)
    }
}
