import SwiftUI
import EventKit

enum ViewMode: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    var id: String { rawValue }
}

struct EditorContext: Identifiable {
    let id = UUID()
    let event: EKEvent
    let isNew: Bool
}

@MainActor
final class AppState: ObservableObject {
    @Published var currentDate = Date()
    @Published var viewMode: ViewMode = .week
    @Published var editorContext: EditorContext?

    let calendar = Calendar.autoupdatingCurrent

    func goToToday() { currentDate = Date() }

    func step(_ direction: Int) {
        let component: Calendar.Component
        switch viewMode {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        currentDate = calendar.date(byAdding: component, value: direction, to: currentDate) ?? currentDate
    }

    func newEvent(store: CalendarStore, start: Date? = nil, end: Date? = nil, allDay: Bool = false) {
        guard store.accessState == .granted else { return }
        let event = EKEvent(eventStore: store.eventStore)
        let startDate = start ?? defaultStart
        event.startDate = startDate
        event.endDate = end ?? startDate.addingTimeInterval(3600)
        event.isAllDay = allDay
        event.calendar = store.defaultCalendar
        editorContext = EditorContext(event: event, isNew: true)
    }

    func edit(_ event: EKEvent) {
        editorContext = EditorContext(event: event, isNew: false)
    }

    // Next round hour on the currently shown day
    private var defaultStart: Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: currentDate)
        comps.hour = min(calendar.component(.hour, from: Date()) + 1, 23)
        return calendar.date(from: comps) ?? currentDate
    }
}
