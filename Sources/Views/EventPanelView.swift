import SwiftUI
import EventKit

enum RecurrenceChoice: String, CaseIterable, Identifiable {
    case none = "Does not repeat"
    case daily = "Every day"
    case weekdays = "Every weekday"
    case weekly = "Every week"
    case biweekly = "Every 2 weeks"
    case monthly = "Every month"
    case yearly = "Every year"

    var id: String { rawValue }

    var rule: EKRecurrenceRule? {
        switch self {
        case .none:
            return nil
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays:
            let days: [EKRecurrenceDayOfWeek] = [.monday, .tuesday, .wednesday, .thursday, .friday]
                .map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(
                recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: nil
            )
        case .weekly:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .biweekly:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly:
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }

    static func from(_ event: EKEvent) -> RecurrenceChoice {
        guard let rule = event.recurrenceRules?.first else { return .none }
        switch rule.frequency {
        case .daily: return .daily
        case .weekly:
            if rule.interval == 2 { return .biweekly }
            if (rule.daysOfTheWeek?.count ?? 0) == 5 { return .weekdays }
            return .weekly
        case .monthly: return .monthly
        case .yearly: return .yearly
        @unknown default: return .none
        }
    }
}

/// Notion-style right-hand event panel: details + inline editing.
struct EventPanelView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let context: EditorContext

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var notes: String
    @State private var urlString: String
    @State private var calendarID: String
    @State private var recurrence: RecurrenceChoice
    private let originalSnapshot: EventSnapshot?
    @FocusState private var titleFocused: Bool

    init(context: EditorContext) {
        self.context = context
        _title = State(initialValue: context.event.title ?? "")
        _isAllDay = State(initialValue: context.event.isAllDay)
        _start = State(initialValue: context.event.startDate ?? Date())
        _end = State(initialValue: context.event.endDate ?? Date().addingTimeInterval(3600))
        _location = State(initialValue: context.event.location ?? "")
        _notes = State(initialValue: context.event.notes ?? "")
        _urlString = State(initialValue: context.event.url?.absoluteString ?? "")
        _calendarID = State(initialValue: context.event.calendar?.calendarIdentifier ?? "")
        _recurrence = State(initialValue: RecurrenceChoice.from(context.event))
        originalSnapshot = context.isNew ? nil : EventSnapshot(context.event)
    }

    private var isReadOnly: Bool {
        !context.isNew && !(context.event.calendar?.allowsContentModifications ?? true)
    }

    private var selectedCalendar: EKCalendar? {
        store.calendars.first { $0.calendarIdentifier == calendarID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !context.isNew, !isReadOnly {
                    Button {
                        appState.requestDelete(context.event, store: store)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete (⌫)")
                }
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close (esc)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Add title", text: $title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .focused($titleFocused)
                        .lineLimit(3)

                    if let joinURL = MeetLink.url(for: context.event) {
                        Button {
                            openURL(joinURL)
                        } label: {
                            Label("Join meeting", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    row(icon: "clock") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("All day", isOn: $isAllDay)
                                .font(.callout)
                            DatePicker(
                                "Starts",
                                selection: $start,
                                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                            )
                            .font(.callout)
                            DatePicker(
                                "Ends",
                                selection: $end,
                                in: start...,
                                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                            )
                            .font(.callout)
                        }
                    }

                    row(icon: "repeat") {
                        Picker("", selection: $recurrence) {
                            ForEach(RecurrenceChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    row(icon: "calendar") {
                        Picker("", selection: $calendarID) {
                            ForEach(context.isNew || !isReadOnly ? store.writableCalendars : store.calendars, id: \.calendarIdentifier) { cal in
                                Text(cal.title).tag(cal.calendarIdentifier)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let attendees = context.event.attendees, !attendees.isEmpty {
                        row(icon: "person.2") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                                    HStack(spacing: 6) {
                                        Image(systemName: statusIcon(attendee.participantStatus))
                                            .font(.system(size: 10))
                                            .foregroundStyle(statusColor(attendee.participantStatus))
                                        Text(attendee.name ?? "Unknown")
                                            .font(.callout)
                                            .lineLimit(1)
                                        if attendee.isCurrentUser {
                                            Text("(you)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    row(icon: "mappin.and.ellipse") {
                        TextField("Add location", text: $location)
                            .textFieldStyle(.plain)
                            .font(.callout)
                    }

                    row(icon: "link") {
                        TextField("Add URL", text: $urlString)
                            .textFieldStyle(.plain)
                            .font(.callout)
                    }

                    row(icon: "text.alignleft") {
                        TextEditor(text: $notes)
                            .font(.callout)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(14)
            }
            .disabled(isReadOnly)

            Divider()
            HStack {
                if isReadOnly {
                    Text("Read-only calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(context.isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isReadOnly)
            }
            .padding(12)
        }
        .background(BackgroundColor())
        .onChange(of: start) { oldValue, newValue in
            end = end.addingTimeInterval(newValue.timeIntervalSince(oldValue))
        }
        .onAppear {
            if context.isNew { titleFocused = true }
        }
    }

    private func row(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 3)
            content()
        }
    }

    private func statusIcon(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        default: return "circle"
        }
    }

    private func statusColor(_ status: EKParticipantStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        default: return .secondary
        }
    }

    private func close() {
        appState.closePanel()
        dismiss()
    }

    private func save() {
        let event = context.event
        event.title = title.isEmpty ? "New event" : title
        event.isAllDay = isAllDay
        event.startDate = start
        event.endDate = max(end, isAllDay ? start : start.addingTimeInterval(900))
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        event.url = urlString.isEmpty ? nil : URL(string: urlString)
        if RecurrenceChoice.from(event) != recurrence {
            event.recurrenceRules = recurrence.rule.map { [$0] }
        }
        if let cal = store.writableCalendars.first(where: { $0.calendarIdentifier == calendarID }),
           cal.calendarIdentifier != event.calendar?.calendarIdentifier {
            event.calendar = cal
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendar
        }
        appState.commitChange(to: event, snapshot: originalSnapshot, isNew: context.isNew, store: store)
        appState.closePanel()
        dismiss()
    }
}

private struct BackgroundColor: View {
    var body: some View {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
