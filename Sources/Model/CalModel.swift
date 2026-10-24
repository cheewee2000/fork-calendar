import SwiftUI

/// Google attendee responseStatus.
enum ParticipantStatus: String, Codable {
    case needsAction, accepted, declined, tentative

    init(google raw: String?) {
        self = ParticipantStatus(rawValue: raw ?? "") ?? .needsAction
    }
}

struct CalAttendee: Codable, Hashable {
    var email: String
    var displayName: String?
    var responseStatus: ParticipantStatus
    var isSelf: Bool
    var isOrganizer: Bool
    var isOptional: Bool
    var isResource: Bool

    var name: String? { displayName ?? email }

    func googleJSON() -> [String: Any] {
        var d: [String: Any] = ["email": email, "responseStatus": responseStatus.rawValue]
        if let displayName { d["displayName"] = displayName }
        if isOptional { d["optional"] = true }
        if isResource { d["resource"] = true }
        return d
    }
}

/// Which occurrences an edit/delete of a recurring event applies to.
enum EditSpan {
    case thisEvent
    case futureEvents
}

/// A Google calendar belonging to one signed-in account.
final class CalCalendar: Codable, Identifiable, Hashable {
    /// "\(accountID)|\(googleID)" — unique across accounts.
    let calendarIdentifier: String
    let googleID: String
    let accountID: String
    var title: String
    var colorHex: String?
    var accessRole: String
    var isPrimary: Bool
    var timeZone: String?

    init(googleID: String, accountID: String, title: String, colorHex: String?, accessRole: String, isPrimary: Bool, timeZone: String?) {
        self.calendarIdentifier = CalCalendar.key(account: accountID, calendar: googleID)
        self.googleID = googleID
        self.accountID = accountID
        self.title = title
        self.colorHex = colorHex
        self.accessRole = accessRole
        self.isPrimary = isPrimary
        self.timeZone = timeZone
    }

    static func key(account: String, calendar: String) -> String { account + "|" + calendar }

    var id: String { calendarIdentifier }
    var allowsContentModifications: Bool { accessRole == "owner" || accessRole == "writer" }

    var displayColor: Color {
        if let hex = AppSettings.shared.calendarColors[calendarIdentifier], let c = Color(hex: hex) { return c }
        if let hex = colorHex, let c = Color(hex: hex.replacingOccurrences(of: "#", with: "")) { return c }
        return .accentColor
    }

    static func == (a: CalCalendar, b: CalCalendar) -> Bool { a.calendarIdentifier == b.calendarIdentifier }
    func hash(into hasher: inout Hasher) { hasher.combine(calendarIdentifier) }
}

/// Persisted, value-type form of an event (the sync engine's truth).
struct EventRecord: Codable, Hashable {
    var id: String
    var calendarKey: String
    var iCalUID: String?
    var status: String
    var title: String?
    var notes: String?
    var location: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var timeZone: String?
    var url: String?
    var recurrence: [String]?
    var recurringEventId: String?
    var originalStart: Date?
    var attendees: [CalAttendee]?
    var organizerEmail: String?
    var organizerSelf: Bool
    var hangoutLink: String?
    var htmlLink: String?
    var etag: String?
    var updated: Date?
    var colorId: String?
    var transparency: String?
    var guestsCanModify: Bool
    var eventType: String? = nil
}

/// Mutable, identity-based event object the views edit in place (what EKEvent
/// used to be). Built from an `EventRecord`; `record()` turns it back.
final class CalEvent: Identifiable, Hashable {
    var id: String
    var calendar: CalCalendar?
    var title: String?
    var startDate: Date!
    var endDate: Date!
    var isAllDay: Bool = false
    var location: String?
    var notes: String?
    var url: URL?
    var attendees: [CalAttendee]?
    var organizerEmail: String?
    var organizerSelf = false
    var hangoutLink: String?
    var htmlLink: String?
    var iCalUID: String?
    /// Set on instances of a recurring series (Google's `recurringEventId`).
    var recurringEventId: String?
    var originalStart: Date?
    /// RRULE lines — own rules on a master, the master's rules on an instance.
    var recurrence: [String]?
    var status = "confirmed"
    var etag: String?
    var updated: Date?
    var colorId: String?
    var timeZone: String?
    var transparency: String?
    var guestsCanModify = false
    /// Google's `eventType` (default, fromGmail, birthday, …).
    var eventType: String?
    /// Set by the editor: create a Google Meet link on the next save.
    var wantsMeet = false

    static let localPrefix = "local-"

    init() {
        id = CalEvent.localPrefix + UUID().uuidString
    }

    init(record r: EventRecord, calendar: CalCalendar?) {
        id = r.id
        self.calendar = calendar
        title = r.title
        startDate = r.start
        endDate = r.end
        isAllDay = r.isAllDay
        location = r.location
        notes = r.notes
        url = r.url.flatMap(URL.init(string:))
        attendees = r.attendees
        organizerEmail = r.organizerEmail
        organizerSelf = r.organizerSelf
        hangoutLink = r.hangoutLink
        htmlLink = r.htmlLink
        iCalUID = r.iCalUID
        recurringEventId = r.recurringEventId
        originalStart = r.originalStart
        recurrence = r.recurrence
        status = r.status
        etag = r.etag
        updated = r.updated
        colorId = r.colorId
        timeZone = r.timeZone
        transparency = r.transparency
        guestsCanModify = r.guestsCanModify
        eventType = r.eventType
    }

    func record() -> EventRecord {
        EventRecord(
            id: id,
            calendarKey: calendar?.calendarIdentifier ?? "",
            iCalUID: iCalUID,
            status: status,
            title: title,
            notes: notes,
            location: location,
            start: startDate ?? Date(),
            end: endDate ?? Date(),
            isAllDay: isAllDay,
            timeZone: timeZone,
            url: url?.absoluteString,
            recurrence: recurrence,
            recurringEventId: recurringEventId,
            originalStart: originalStart,
            attendees: attendees,
            organizerEmail: organizerEmail,
            organizerSelf: organizerSelf,
            hangoutLink: hangoutLink,
            htmlLink: htmlLink,
            etag: etag,
            updated: updated,
            colorId: colorId,
            transparency: transparency,
            guestsCanModify: guestsCanModify,
            eventType: eventType
        )
    }

    // MARK: EventKit-shaped conveniences the views rely on

    var eventIdentifier: String? { id }
    /// Writable calendar and an event kind Google lets us change. Events from
    /// Gmail and birthdays reject start/end edits with a bare 400 Bad Request.
    var canEdit: Bool {
        calendar?.allowsContentModifications == true && !CalEvent.lockedTypes.contains(eventType ?? "default")
    }
    static let lockedTypes: Set<String> = ["fromGmail", "birthday"]
    var isLocal: Bool { id.hasPrefix(CalEvent.localPrefix) }
    var isInstance: Bool { recurringEventId != nil }
    var isMaster: Bool { recurringEventId == nil && !(recurrence ?? []).isEmpty }
    /// Google instance ids carry the master id before "_".
    var masterID: String? { recurringEventId ?? (isMaster ? id : nil) }

    var myParticipantStatus: ParticipantStatus? {
        attendees?.first(where: { $0.isSelf })?.responseStatus
    }
    /// True when I'm invited but haven't responded yet.
    var needsMyResponse: Bool { myParticipantStatus == .needsAction }
    /// Guests other than me (the ones Google would notify).
    var otherAttendees: [CalAttendee] { (attendees ?? []).filter { !$0.isSelf } }

    static func == (a: CalEvent, b: CalEvent) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
