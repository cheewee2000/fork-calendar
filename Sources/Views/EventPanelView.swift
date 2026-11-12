import SwiftUI

enum RecurrenceChoice: String, CaseIterable, Identifiable {
    case none = "Does not repeat"
    case daily = "Every day"
    case weekdays = "Every weekday"
    case weekly = "Every week"
    case biweekly = "Every 2 weeks"
    case monthly = "Every month"
    case yearly = "Every year"

    var id: String { rawValue }

    /// RFC 5545 lines as Google stores them.
    var rules: [String]? {
        switch self {
        case .none: return nil
        case .daily: return ["RRULE:FREQ=DAILY"]
        case .weekdays: return ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]
        case .weekly: return ["RRULE:FREQ=WEEKLY"]
        case .biweekly: return ["RRULE:FREQ=WEEKLY;INTERVAL=2"]
        case .monthly: return ["RRULE:FREQ=MONTHLY"]
        case .yearly: return ["RRULE:FREQ=YEARLY"]
        }
    }

    static func from(_ event: CalEvent) -> RecurrenceChoice {
        let parts = RRule.parts(event.recurrence)
        guard !parts.isEmpty else { return .none }
        let interval = Int(parts["INTERVAL"] ?? "1") ?? 1
        switch parts["FREQ"] {
        case "DAILY": return .daily
        case "WEEKLY":
            if interval == 2 { return .biweekly }
            if (parts["BYDAY"]?.split(separator: ",").count ?? 0) == 5 { return .weekdays }
            return .weekly
        case "MONTHLY": return .monthly
        case "YEARLY": return .yearly
        default: return .none
        }
    }
}

/// Notion-style right-hand event panel: details + inline editing.
struct EventPanelView: View {
    @EnvironmentObject var store: CalendarStore
    @Environment(AppState.self) var appState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let context: EditorContext
    /// True only when presented as a sheet (iOS compact). The inline macOS
    /// panel must NOT call dismiss() — that dismisses the whole window.
    var isSheet = false

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    /// Zone the start/end pickers read and write wall-clock time in.
    @State private var timeZoneID: String
    /// "Describe it" box (new events): typed text, the model's pending
    /// question, and the assistant that remembers the exchange.
    @State private var describeText = ""
    @State private var describeQuestion: String?
    @State private var describeBusy = false
    @State private var assistant = EventAssistant()
    @State private var location: String
    @State private var notes: String
    @State private var urlString: String
    @State private var calendarID: String
    @State private var recurrence: RecurrenceChoice
    enum RepeatEnd: String, CaseIterable, Identifiable {
        case never = "Never ends", onDate = "Ends on", after = "Ends after"
        var id: String { rawValue }
    }
    @State private var repeatEnd: RepeatEnd
    @State private var repeatUntil: Date
    @State private var repeatCount: Int
    @State private var inviteEmails: String = ""
    @State private var addMeetOnSave = false
    @State private var editingNotes = false
    @State private var renderedNotes: AttributedString?
    private let originalSnapshot: EventSnapshot?
    @FocusState private var titleFocused: Bool
    @FocusState private var describeFocused: Bool
    @FocusState private var inviteFocused: Bool

    init(context: EditorContext, isSheet: Bool = false) {
        self.context = context
        self.isSheet = isSheet
        _title = State(initialValue: context.event.title ?? "")
        _isAllDay = State(initialValue: context.event.isAllDay)
        _start = State(initialValue: context.event.startDate ?? Date())
        _end = State(initialValue: context.event.endDate ?? Date().addingTimeInterval(3600))
        _timeZoneID = State(initialValue: context.event.timeZone ?? TimeZone.autoupdatingCurrent.identifier)
        _location = State(initialValue: context.event.location ?? "")
        _notes = State(initialValue: context.event.notes ?? "")
        _urlString = State(initialValue: context.event.url?.absoluteString ?? "")
        _calendarID = State(initialValue: context.event.calendar?.calendarIdentifier ?? "")
        _recurrence = State(initialValue: RecurrenceChoice.from(context.event))
        let until = RRule.untilDay(context.event.recurrence), count = RRule.count(context.event.recurrence)
        _repeatEnd = State(initialValue: until != nil ? .onDate : count != nil ? .after : .never)
        _repeatUntil = State(initialValue: until ?? Calendar.autoupdatingCurrent.date(byAdding: .month, value: 3, to: context.event.startDate ?? Date()) ?? Date())
        _repeatCount = State(initialValue: count ?? 10)
        originalSnapshot = context.isNew ? nil : EventSnapshot(context.event)
    }

    // MARK: - Invite autocomplete

    /// The email fragment being typed (after the last comma).
    private var inviteToken: String {
        let last = inviteEmails.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? inviteEmails
        return last.trimmingCharacters(in: .whitespaces)
    }

    private var inviteSuggestions: [CalendarStore.AttendeeSuggestion] {
        guard inviteFocused, !isReadOnly else { return [] }
        let token = inviteToken.lowercased()
        guard !token.isEmpty else { return [] }
        // Don't re-suggest people already on the event or earlier in the field.
        var taken = Set((context.event.attendees ?? []).map { $0.email.lowercased() })
        for part in inviteEmails.split(separator: ",").dropLast() {
            taken.insert(part.trimmingCharacters(in: .whitespaces).lowercased())
        }
        let matches = store.attendeeSuggestions(matching: token, excluding: taken)
        if matches.count == 1, matches[0].email == token { return [] } // already typed in full
        return matches
    }

    private func acceptInviteSuggestion(_ s: CalendarStore.AttendeeSuggestion) {
        var parts = inviteEmails.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = s.email
        inviteEmails = parts.joined(separator: ", ") + ", "
        inviteFocused = true
    }

    private func acceptFirstInviteSuggestion() {
        if let first = inviteSuggestions.first { acceptInviteSuggestion(first) }
    }

    private var isReadOnly: Bool {
        !context.isNew && !context.event.canEdit
    }

    /// All-day pickers show the last day the event covers; the model (like
    /// Google) keeps an exclusive end — midnight after that last day.
    private var inclusiveEnd: Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.autoupdatingCurrent
                return cal.startOfDay(for: max(end.addingTimeInterval(-1), start))
            },
            set: {
                let cal = Calendar.autoupdatingCurrent
                let lastDay = cal.startOfDay(for: $0)
                end = cal.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            }
        )
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
                if !context.isNew {
                    Button {
                        appState.billEvent(context.event)
                    } label: {
                        Image(systemName: "dollarsign.circle")
                    }
                    .help("Bill to invoice (B)")
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
                        .font(CWT.mono(15))
                        .focused($titleFocused)
                        .lineLimit(3)
                        .disabled(isReadOnly)

                    if let joinURL = currentJoinURL {
                        Button {
                            openURL(joinURL)
                        } label: {
                            Label("Join meeting", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .prominentLabel()
                    } else if addMeetOnSave {
                        Label("Google Meet will be created on save", systemImage: "video.badge.checkmark")
                            .font(CWT.mono(12))
                            .foregroundStyle(CWT.inkSoft)
                    } else if !isReadOnly {
                        conferencingMenu
                    }

                    row(icon: "clock") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("All day", isOn: $isAllDay)
                                .font(CWT.mono(12))
                            DatePicker(
                                "Starts",
                                selection: $start,
                                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                            )
                            .font(CWT.mono(12))
                            DatePicker(
                                "Ends",
                                selection: isAllDay ? inclusiveEnd : $end,
                                in: (isAllDay ? Calendar.autoupdatingCurrent.startOfDay(for: start) : start)...,
                                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                            )
                            .font(CWT.mono(12))
                            if !isAllDay {
                                Picker("Time zone", selection: $timeZoneID) {
                                    ForEach(timeZoneChoices, id: \.self) { id in
                                        Text(timeZoneTitle(id)).tag(id)
                                    }
                                }
                                .font(CWT.mono(12))
                            }
                        }
                        // The pickers show the event's zone, not the Mac's.
                        .environment(\.timeZone, pickerZone)
                        .environment(\.calendar, pickerCalendar)
                        .onChange(of: timeZoneID) { old, new in
                            // Keep the wall-clock time: 3 PM stays 3 PM in the
                            // new zone, so the instant moves by the offset gap.
                            // ponytail: offsets taken at the start instant; an
                            // event straddling a DST change shifts by one gap.
                            guard !assistant.settingZone,
                                  let from = TimeZone(identifier: old), let to = TimeZone(identifier: new) else { return }
                            let shift = TimeInterval(from.secondsFromGMT(for: start) - to.secondsFromGMT(for: start))
                            start += shift // the end follows (onChange(of: start))
                        }
                        .disabled(isReadOnly)
                    }

                    row(icon: "repeat") {
                        Picker("", selection: $recurrence) {
                            ForEach(RecurrenceChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(isReadOnly)
                    }

                    if recurrence != .none {
                        row(icon: "repeat.1") {
                            HStack(spacing: 8) {
                                Picker("", selection: $repeatEnd) {
                                    ForEach(RepeatEnd.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                switch repeatEnd {
                                case .never: EmptyView()
                                case .onDate:
                                    DatePicker("", selection: $repeatUntil, in: start..., displayedComponents: [.date])
                                        .labelsHidden()
                                        .font(CWT.mono(12))
                                case .after:
                                    Stepper("\(repeatCount) times", value: $repeatCount, in: 1...999)
                                        .font(CWT.mono(12))
                                        .fixedSize()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(isReadOnly)
                        }
                    }

                    row(icon: "calendar") {
                        Picker("", selection: $calendarID) {
                            ForEach(context.isNew || !isReadOnly ? store.writableCalendars : store.orderedCalendars, id: \.calendarIdentifier) { cal in
                                Text(cal.title).tag(cal.calendarIdentifier)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(isReadOnly)
                    }

                    if !context.isNew, context.event.attendees?.isEmpty == false {
                        row(icon: "envelope.badge") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your response")
                                    .font(CWT.mono(10))
                                    .foregroundStyle(CWT.inkSoft)
                                HStack(spacing: 6) {
                                    rsvpButton("Going", status: .accepted)
                                    rsvpButton("Maybe", status: .tentative)
                                    rsvpButton("No", status: .declined)
                                }
                            }
                        }
                    }

                    if let attendees = context.event.attendees, !attendees.isEmpty {
                        row(icon: "person.2") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                                    let status = attendee.responseStatus
                                    HStack(spacing: 6) {
                                        Image(systemName: statusIcon(status))
                                            .font(CWT.mono(10))
                                            .foregroundStyle(statusColor(status))
                                        Text(attendee.name ?? "Unknown")
                                            .font(CWT.mono(12))
                                            .lineLimit(1)
                                        if attendee.isSelf {
                                            Text("(you)").font(CWT.mono(10)).foregroundStyle(CWT.inkSoft)
                                        } else if attendee.isOrganizer {
                                            Text("(organizer)").font(CWT.mono(10)).foregroundStyle(CWT.inkSoft)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    row(icon: "person.badge.plus") {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Invite people (emails, comma-separated)", text: $inviteEmails)
                                .textFieldStyle(.plain)
                                .font(CWT.mono(12))
                                .disabled(isReadOnly)
                                .focused($inviteFocused)
                                .onSubmit(acceptFirstInviteSuggestion)
                                #if os(iOS)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                #endif
                            // Lookup from past events' guests: click (or press
                            // return for the top hit) to complete the token
                            // being typed after the last comma.
                            ForEach(inviteSuggestions) { s in
                                Button {
                                    acceptInviteSuggestion(s)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.crop.circle")
                                            .font(CWT.mono(10))
                                            .foregroundStyle(CWT.inkSoft)
                                        if let name = s.name, !name.isEmpty, name.lowercased() != s.email {
                                            Text(name).font(CWT.mono(11)).lineLimit(1)
                                            Text(s.email).font(CWT.mono(10))
                                                .foregroundStyle(CWT.inkSoft).lineLimit(1)
                                        } else {
                                            Text(s.email).font(CWT.mono(11)).lineLimit(1)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if !inviteEmails.isEmpty {
                                Text(settings.guestNotifyPolicy == .never
                                     ? "Added to the guest list on save (no email — see Settings)"
                                     : "Added to the guest list and emailed on save")
                                    .font(CWT.mono(9))
                                    .foregroundStyle(CWT.inkFaint)
                            }
                        }
                    }

                    row(icon: "mappin.and.ellipse") {
                        HStack(spacing: 6) {
                            TextField("Add location", text: $location)
                                .textFieldStyle(.plain)
                                .font(CWT.mono(12))
                                .disabled(isReadOnly)
                            if let maps = mapsURL {
                                Button {
                                    openURL(maps)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(CWT.mono(12))
                                        .foregroundStyle(CWT.inkSoft)
                                }
                                .buttonStyle(.plain)
                                .help("Open in Google Maps")
                            }
                        }
                    }

                    row(icon: "link") {
                        TextField("Add URL", text: $urlString)
                            .textFieldStyle(.plain)
                            .font(CWT.mono(12))
                            .disabled(isReadOnly)
                    }

                    row(icon: "text.alignleft") {
                        VStack(alignment: .leading, spacing: 4) {
                            if !editingNotes, HTMLNotes.looksLikeHTML(notes) {
                                // Google descriptions are usually HTML; show
                                // them formatted, with links tappable.
                                Text(renderedNotes ?? AttributedString())
                                    .font(CWT.mono(12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(CWT.paper2, in: Rectangle())
                                if !isReadOnly {
                                    Button("Edit notes") { editingNotes = true }
                                        .buttonStyle(.plain)
                                        .font(CWT.mono(10))
                                        .foregroundStyle(CWT.inkSoft)
                                }
                            } else {
                                TextEditor(text: $notes)
                                    .font(CWT.mono(12))
                                    .frame(minHeight: 70)
                                    .scrollContentBackground(.hidden)
                                    .background(CWT.paper2, in: Rectangle())
                                    .disabled(isReadOnly)
                            }
                        }
                    }
                }
                .padding(14)
            }

            if context.isNew { describeBox }
            Divider()
            HStack {
                if isReadOnly {
                    Text("Read-only calendar")
                        .font(CWT.mono(10))
                        .foregroundStyle(CWT.inkSoft)
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(context.isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .prominentLabel()
                    .disabled(isReadOnly)
            }
            .padding(12)
        }
        // Controls (buttons, pickers, toggles) don't inherit the root font.
        .font(CWT.mono(12))
        .background(BackgroundColor())
        .onChange(of: start) { oldValue, newValue in
            // Moving the start keeps the duration — except when the describe
            // box just set both ends itself.
            guard !assistant.settingZone else { return }
            end = end.addingTimeInterval(newValue.timeIntervalSince(oldValue))
        }
        // The placeholder block on the calendar follows the form.
        .onChange(of: [start, end]) { syncPlaceholder() }
        .onChange(of: isAllDay) { syncPlaceholder() }
        .onAppear {
            // A new event opens with the cursor in the describe box (the
            // title when Apple Intelligence isn't available).
            if context.isNew {
                if EventAssistant.unavailableReason == nil { describeFocused = true } else { titleFocused = true }
            }
        }
        // Never render inside body: the HTML importer spins the run loop
        // (WebKit), which re-entered SwiftUI mid-update and left the iPhone
        // sheet blank for every event with an HTML description.
        .task {
            renderedNotes = HTMLNotes.render(notes)
            if renderedNotes == nil { editingNotes = true }
        }
    }

    /// Google Maps search link for the location text. A location that is
    /// itself a URL (e.g. a pasted meeting link) gets no maps link.
    private var mapsURL: URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") { return nil }
        var comps = URLComponents(string: "https://www.google.com/maps/search/")!
        comps.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: trimmed),
        ]
        return comps.url
    }

    /// Join link considering unsaved edits to the URL field.
    private var currentJoinURL: URL? {
        if let typed = URL(string: urlString), MeetLink.isMeetingURL(typed) { return typed }
        return MeetLink.url(for: context.event)
    }

    private var conferencingMenu: some View {
        Menu {
            Button {
                addMeetOnSave = true
            } label: {
                Label("Google Meet (created on save)", systemImage: "video.badge.plus")
            }
            if let zoomURL = URL(string: settings.zoomLink), !settings.zoomLink.isEmpty {
                Button {
                    urlString = zoomURL.absoluteString
                    if location.isEmpty { location = "Zoom" }
                } label: {
                    Label("Zoom (personal meeting)", systemImage: "video")
                }
            } else {
                Button("Zoom — set your personal link in Settings…") {}
                    .disabled(true)
            }
            Button {
                if let pasted = Clipboard.paste(),
                   let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.hasPrefix("http") == true {
                    urlString = url.absoluteString
                }
            } label: {
                Label("Paste link from clipboard", systemImage: "doc.on.clipboard")
            }
        } label: {
            Label("Add conferencing", systemImage: "video")
                .frame(maxWidth: .infinity)
        }
    }

    private func row(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(CWT.mono(13))
                .foregroundStyle(CWT.inkSoft)
                .frame(width: 18)
                .padding(.top, 3)
            content()
        }
    }

    private func rsvpButton(_ label: String, status: ParticipantStatus) -> some View {
        let isCurrent = context.event.myParticipantStatus == status
        return Button(label) {
            let event = context.event
            let s = store
            Task { await s.respond(event, status: status) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isCurrent ? .accentColor : nil)
    }

    private func statusIcon(_ status: ParticipantStatus) -> String {
        switch status {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        default: return "circle"
        }
    }

    private func statusColor(_ status: ParticipantStatus) -> Color {
        switch status {
        case .accepted: return CWT.signalGreen
        case .declined: return CWT.signalRed
        case .tentative: return CWT.signalOrange
        default: return CWT.inkSoft
        }
    }

    private func close() {
        appState.closePanel()
        if isSheet { dismiss() }
    }

    /// Type the event in words; Return fills the form above. Nothing is
    /// saved from here — an unclear description comes back as a question.
    @ViewBuilder private var describeBox: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            if let reason = EventAssistant.unavailableReason {
                Text(reason).foregroundStyle(CWT.inkFaint)
            } else {
                if let q = describeQuestion {
                    Text(q).foregroundStyle(CWT.signalOrange)
                }
                HStack(alignment: .top, spacing: 6) {
                    TextField(describeQuestion == nil ? "Describe it: dinner Fri 7pm Tokyo time at Nobu…" : "Answer…",
                              text: $describeText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...5)
                        .focused($describeFocused)
                        .onSubmit { describe() }
                        .disabled(describeBusy)
                    if describeBusy { ProgressView().controlSize(.small) }
                }
            }
        }
        .font(CWT.mono(12))
        .padding(12)
        .onChange(of: appState.debugDescribe) { _, text in
            describeText = text
            describe()
        }
    }

    private func syncPlaceholder() {
        guard context.isNew else { return }
        context.event.startDate = start
        context.event.endDate = end
        context.event.isAllDay = isAllDay
        appState.panelContext = context // CalEvent is a plain class: re-set to redraw
    }

    private func describe() {
        let text = describeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !describeBusy else { return }
        describeBusy = true
        Task {
            // The field is disabled while busy, which drops its focus;
            // put the cursor back for the answer or a correction.
            defer { describeBusy = false; DispatchQueue.main.async { describeFocused = true } }
            do {
                let f = try await assistant.fields(from: text, defaultMinutes: settings.defaultDuration)
                if let t = f.title { title = t }
                if let s = f.start, let e = f.end {
                    isAllDay = f.allDay
                    // The model's dates are already instants in its zone;
                    // the zone picker's keep-wall-clock shift must skip them.
                    assistant.settingZone = true
                    timeZoneID = f.timeZone ?? TimeZone.autoupdatingCurrent.identifier
                    start = s
                    // Next tick: the Ends picker's range still starts at the
                    // old start during this update and would clamp an
                    // earlier end back up to it.
                    DispatchQueue.main.async { end = e }
                    // Show the day it landed on, if it isn't on screen.
                    let cal = appState.calendar
                    if appState.viewMode.zoomFamily == .grid,
                       !appState.visibleDays.contains(where: { cal.isDate($0, inSameDayAs: s) }) {
                        appState.goTo(s)
                    }
                    // Cleared after this update's onChange handlers have run.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { assistant.settingZone = false }
                }
                if let l = f.location { location = l }
                if let u = f.url { urlString = u }
                if let r = f.repeats { recurrence = r }
                if !f.invitees.isEmpty { inviteEmails = f.invitees.joined(separator: ", ") }
                if f.meet { addMeetOnSave = true }
                describeQuestion = f.question
                describeText = ""
            } catch {
                describeQuestion = "Couldn't read that (\(error.localizedDescription)). Try rephrasing."
            }
        }
    }

    private var pickerZone: TimeZone {
        isAllDay ? .autoupdatingCurrent : TimeZone(identifier: timeZoneID) ?? .autoupdatingCurrent
    }

    private var pickerCalendar: Calendar {
        var cal = Calendar.autoupdatingCurrent
        cal.timeZone = pickerZone
        return cal
    }

    /// This Mac's zone, the event's own, then the curated list.
    private var timeZoneChoices: [String] {
        var seen = Set<String>()
        return ([TimeZone.autoupdatingCurrent.identifier, timeZoneID] + AppSettings.curatedTimeZones)
            .filter { seen.insert($0).inserted }
    }

    private func timeZoneTitle(_ id: String) -> String {
        "\(AppSettings.timeZoneLabel(id)) \(TimeZone(identifier: id)?.abbreviation(for: start) ?? "")"
    }

    private func save() {
        let event = context.event
        if !isAllDay, timeZoneID != event.timeZone ?? TimeZone.autoupdatingCurrent.identifier {
            event.timeZone = timeZoneID
        }
        event.title = title.isEmpty ? "New event" : title
        event.isAllDay = isAllDay
        if isAllDay {
            // Normalize to whole days with an exclusive end, so a one-day
            // event spans exactly one day (Google rejects an empty range).
            let cal = Calendar.autoupdatingCurrent
            let firstDay = cal.startOfDay(for: start)
            let lastDay = cal.startOfDay(for: max(end.addingTimeInterval(-1), firstDay))
            event.startDate = firstDay
            event.endDate = cal.date(byAdding: .day, value: 1, to: lastDay) ?? end
        } else {
            event.startDate = start
            event.endDate = max(end, start.addingTimeInterval(900))
        }
        event.location = location.isEmpty ? nil : location
        event.notes = notes.isEmpty ? nil : notes
        event.url = urlString.isEmpty ? nil : URL(string: urlString)
        let newRules = recurrence.rules.map {
            RRule.ending($0, onDay: repeatEnd == .onDate ? repeatUntil : nil,
                         count: repeatEnd == .after ? repeatCount : nil, allDay: event.isAllDay)
        }
        let endChanged = RRule.untilDay(newRules).map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
            != RRule.untilDay(event.recurrence).map { Calendar.autoupdatingCurrent.startOfDay(for: $0) }
            || RRule.count(newRules) != RRule.count(event.recurrence)
        if RecurrenceChoice.from(event) != recurrence || endChanged {
            event.recurrence = newRules
        }
        if let cal = store.writableCalendars.first(where: { $0.calendarIdentifier == calendarID }),
           cal.calendarIdentifier != event.calendar?.calendarIdentifier {
            event.calendar = cal
        } else if event.calendar == nil {
            event.calendar = store.defaultCalendar
        }
        // Guests + Meet ride along with the save (one Google write).
        let emails = inviteEmails.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
        if !emails.isEmpty {
            var list = event.attendees ?? []
            let me = event.calendar?.accountID.lowercased()
            if list.isEmpty, let me {
                // First guest: Google adds the organizer automatically, but
                // listing myself keeps RSVP state visible right away.
                list.append(CalAttendee(email: me, displayName: nil, responseStatus: .accepted,
                                        isSelf: true, isOrganizer: true, isOptional: false, isResource: false))
            }
            for email in emails where !list.contains(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                list.append(CalAttendee(email: email, displayName: nil, responseStatus: .needsAction,
                                        isSelf: false, isOrganizer: false, isOptional: false, isResource: false))
            }
            event.attendees = list
        }
        event.wantsMeet = addMeetOnSave
        appState.commitChange(to: event, snapshot: originalSnapshot, isNew: context.isNew, store: store)
        appState.closePanel()
        if isSheet { dismiss() }
    }
}

/// Renders HTML descriptions into an AttributedString in the app's type.
enum HTMLNotes {
    private static let tagPattern = try! NSRegularExpression(pattern: "<(/?)(a|b|i|u|p|br|div|span|ul|ol|li|strong|em|h[1-6]|table|tr|td|font)\\b[^>]*>", options: [.caseInsensitive])

    static func looksLikeHTML(_ text: String) -> Bool {
        tagPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// nil when the text isn't HTML (the plain editor is used instead).
    static func render(_ text: String) -> AttributedString? {
        guard looksLikeHTML(text), let data = text.data(using: .utf8) else { return nil }
        guard let ns = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        var attr = AttributedString(ns)
        for run in attr.runs {
            var bold = false
            var italic = false
            #if os(macOS)
            if let f = run.appKit.font {
                bold = f.fontDescriptor.symbolicTraits.contains(.bold)
                italic = f.fontDescriptor.symbolicTraits.contains(.italic)
            }
            #else
            if let f = run.uiKit.font {
                bold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                italic = f.fontDescriptor.symbolicTraits.contains(.traitItalic)
            }
            #endif
            let range = run.range
            attr[range].font = CWT.mono(12)
            if italic { attr[range].font = CWT.mono(12).italic() }
            attr[range].foregroundColor = run.link != nil ? Color.accentColor : CWT.ink
            attr[range].backgroundColor = nil
            #if os(macOS)
            attr[range].appKit.paragraphStyle = nil
            #else
            attr[range].uiKit.paragraphStyle = nil
            #endif
        }
        // Trim the trailing newline the HTML importer adds
        while attr.characters.last?.isNewline == true {
            attr.characters.removeLast()
        }
        return attr
    }
}

private struct BackgroundColor: View {
    var body: some View {
        CWT.paper
    }
}
