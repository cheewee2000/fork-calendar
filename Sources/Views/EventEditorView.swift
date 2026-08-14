import SwiftUI
import EventKit

struct EventEditorView: View {
    @EnvironmentObject var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    let context: EditorContext

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var notes: String
    @State private var calendarID: String

    init(context: EditorContext) {
        self.context = context
        _title = State(initialValue: context.event.title ?? "")
        _isAllDay = State(initialValue: context.event.isAllDay)
        _start = State(initialValue: context.event.startDate ?? Date())
        _end = State(initialValue: context.event.endDate ?? Date().addingTimeInterval(3600))
        _location = State(initialValue: context.event.location ?? "")
        _notes = State(initialValue: context.event.notes ?? "")
        _calendarID = State(initialValue: context.event.calendar?.calendarIdentifier ?? "")
    }

    private var isReadOnly: Bool {
        !context.isNew && !(context.event.calendar?.allowsContentModifications ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Event title", text: $title)
                        .font(.title3.weight(.semibold))
                }
                Section {
                    Toggle("All day", isOn: $isAllDay)
                    DatePicker(
                        "Starts",
                        selection: $start,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "Ends",
                        selection: $end,
                        in: start...,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                }
                Section {
                    Picker("Calendar", selection: $calendarID) {
                        ForEach(store.writableCalendars, id: \.calendarIdentifier) { cal in
                            Text(cal.title).tag(cal.calendarIdentifier)
                        }
                    }
                    TextField("Location", text: $location)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }
                if !context.isNew, !isReadOnly {
                    Section {
                        Button("Delete Event", role: .destructive) {
                            store.delete(context.event)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isReadOnly)
            Divider()
            HStack {
                if isReadOnly {
                    Text("Read-only calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(context.isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isReadOnly)
            }
            .padding(12)
        }
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
        .onChange(of: start) { oldValue, newValue in
            // Keep the event duration when the start moves
            end = end.addingTimeInterval(newValue.timeIntervalSince(oldValue))
        }
    }

    private func save() {
        let event = context.event
        event.title = title.isEmpty ? "New event" : title
        event.isAllDay = isAllDay
        event.startDate = start
        event.endDate = max(end, isAllDay ? start : start.addingTimeInterval(900))
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        if let cal = store.writableCalendars.first(where: { $0.calendarIdentifier == calendarID }) {
            event.calendar = cal
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendar
        }
        store.save(event)
        dismiss()
    }
}
