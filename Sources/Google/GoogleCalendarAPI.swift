import Foundation
import EventKit

enum GoogleAPIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = json["error"] as? [String: Any],
                  let message = error["message"] as? String
            else { return "Google returned HTTP \(code)" }
            if message.localizedCaseInsensitiveContains("has not been used")
                || message.localizedCaseInsensitiveContains("is disabled") {
                return "Google Calendar API is disabled for your OAuth project — enable it in console.cloud.google.com (APIs & Services → Library → Google Calendar API)"
            }
            return "Google: \(String(message.prefix(140)))"
        }
    }
}

/// Thin Google Calendar REST client.
enum GoogleCalendarAPI {
    struct GCalendar: Decodable {
        let id: String
        let summary: String
        let accessRole: String?
    }

    private static let base = "https://www.googleapis.com/calendar/v3"

    static func calendarList(token: String) async throws -> [GCalendar] {
        struct ListResponse: Decodable { let items: [GCalendar]? }
        let data = try await get("\(base)/users/me/calendarList?maxResults=250", token: token)
        return (try JSONDecoder().decode(ListResponse.self, from: data)).items ?? []
    }

    /// Google's event id for a CalDAV-synced event, found via its iCal UID.
    static func findEventID(iCalUID: String, calendarID: String, token: String) async throws -> String? {
        struct EventsResponse: Decodable {
            struct Item: Decodable { let id: String; let status: String? }
            let items: [Item]?
        }
        let cal = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        let uid = iCalUID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? iCalUID
        let data = try await get("\(base)/calendars/\(cal)/events?iCalUID=\(uid)", token: token)
        let response = try JSONDecoder().decode(EventsResponse.self, from: data)
        return response.items?.first(where: { $0.status != "cancelled" })?.id
    }

    /// Fallback lookup: exact title within ±36h of the event start.
    static func findEventIDByTime(title: String, start: Date, calendarID: String, token: String) async throws -> String? {
        struct SearchResponse: Decodable {
            struct Item: Decodable { let id: String; let summary: String?; let status: String? }
            let items: [Item]?
        }
        let iso = ISO8601DateFormatter()
        let timeMin = iso.string(from: start.addingTimeInterval(-36 * 3600))
        let timeMax = iso.string(from: start.addingTimeInterval(36 * 3600))
        let cal = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        let q = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title
        let data = try await get("\(base)/calendars/\(cal)/events?q=\(q)&timeMin=\(timeMin)&timeMax=\(timeMax)&maxResults=25", token: token)
        let items = (try JSONDecoder().decode(SearchResponse.self, from: data)).items ?? []
        let matches = items.filter { $0.status != "cancelled" && $0.summary == title }
        // Prefer the series master (no occurrence suffix) so RSVPs cover the series
        return matches.first(where: { !$0.id.contains("_") })?.id ?? matches.first?.id
    }

    static func eventAttendees(eventID: String, calendarID: String, token: String) async throws -> [String] {
        struct Event: Decodable {
            struct Attendee: Decodable { let email: String? }
            let attendees: [Attendee]?
        }
        let cal = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        let data = try await get("\(base)/calendars/\(cal)/events/\(eventID)", token: token)
        let event = try JSONDecoder().decode(Event.self, from: data)
        return event.attendees?.compactMap(\.email) ?? []
    }

    /// Patch attendees (and optionally request a Meet link); notifies guests.
    static func patchEvent(
        eventID: String,
        calendarID: String,
        attendees: [String]?,
        addMeet: Bool,
        token: String
    ) async throws {
        var body: [String: Any] = [:]
        if let attendees {
            body["attendees"] = attendees.map { ["email": $0] }
        }
        if addMeet {
            body["conferenceData"] = [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"],
                ],
            ]
        }
        guard !body.isEmpty else { return }
        let cal = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        let url = "\(base)/calendars/\(cal)/events/\(eventID)?sendUpdates=all&conferenceDataVersion=1"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
    }

    /// RSVP: set my responseStatus on the event's attendee list and notify.
    static func respond(eventID: String, calendarID: String, status: String, token: String) async throws {
        let cal = calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID
        let data = try await get("\(base)/calendars/\(cal)/events/\(eventID)", token: token)
        guard var event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var attendees = event["attendees"] as? [[String: Any]]
        else { throw GoogleAPIError.http(0, "event has no attendees") }
        var found = false
        for i in attendees.indices where (attendees[i]["self"] as? Bool) == true {
            attendees[i]["responseStatus"] = status
            found = true
        }
        guard found else { throw GoogleAPIError.http(0, "you are not on the guest list") }
        event = ["attendees": attendees]
        let url = "\(base)/calendars/\(cal)/events/\(eventID)?sendUpdates=all"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: event)
        let (respData, response) = try await URLSession.shared.data(for: request)
        try check(response, data: respData)
    }

    private static func get(_ url: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return data
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw GoogleAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

/// Bridges EventKit events to Google-side guest lists / Meet links.
@MainActor
enum GoogleSync {
    private static var cachedCalendars: [GoogleCalendarAPI.GCalendar]?

    /// UID forms worth trying: EventKit's external identifier can carry
    /// occurrence suffixes ("…/RID=…") or omit Google's "@google.com".
    static func uidCandidates(for event: EKEvent) -> [String] {
        guard let raw = event.calendarItemExternalIdentifier, !raw.isEmpty else { return [] }
        var forms = [raw]
        if let slash = raw.firstIndex(of: "/") {
            forms.append(String(raw[..<slash]))
        }
        var result: [String] = []
        for form in forms {
            result.append(form)
            if !form.contains("@") { result.append(form + "@google.com") }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Find the Google (calendarID, eventID) for an EventKit event. Tries all
    /// UID forms on the title-matched calendar first, then every calendar,
    /// then falls back to a time-window + exact-title search.
    private static func locateEvent(event: EKEvent, token: String) async throws -> (calendarID: String, eventID: String)? {
        if cachedCalendars == nil {
            cachedCalendars = try await GoogleCalendarAPI.calendarList(token: token)
        }
        let calendars = (cachedCalendars ?? []).filter { $0.accessRole != "freeBusyReader" }
        let calendarTitle = event.calendar?.title ?? ""
        var ordered = calendars.filter {
            $0.summary.caseInsensitiveCompare(calendarTitle) == .orderedSame || $0.id == calendarTitle
        }
        ordered += calendars.filter { cal in !ordered.contains(where: { $0.id == cal.id }) }

        for cal in ordered {
            for uid in uidCandidates(for: event) {
                if let eventID = ((try? await GoogleCalendarAPI.findEventID(iCalUID: uid, calendarID: cal.id, token: token)) ?? nil) {
                    return (cal.id, eventID)
                }
            }
        }
        if let title = event.title, !title.isEmpty, let start = event.startDate {
            for cal in ordered {
                if let eventID = ((try? await GoogleCalendarAPI.findEventIDByTime(title: title, start: start, calendarID: cal.id, token: token)) ?? nil) {
                    return (cal.id, eventID)
                }
            }
        }
        return nil
    }

    /// Attach guests (and optionally a Meet link) to the Google copy of an
    /// EventKit event. Falls back to an emailed .ics invite when Google isn't
    /// connected or the event isn't on a Google calendar.
    static func attachGuests(event: EKEvent, emails: [String], addMeet: Bool, appState: AppState) async {
        let cleanEmails = emails
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        guard !cleanEmails.isEmpty || addMeet else { return }

        guard let token = await GoogleAuth.shared.validToken() else {
            fallback(event: event, emails: cleanEmails, appState: appState,
                     reason: "Google not connected")
            return
        }
        do {
            // The CalDAV push to Google may lag a few seconds for new events
            var located: (calendarID: String, eventID: String)?
            for _ in 0..<8 {
                located = try await locateEvent(event: event, token: token)
                if located != nil { break }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            guard let located else {
                fallback(event: event, emails: cleanEmails, appState: appState,
                         reason: "Event hasn't synced to Google yet")
                return
            }
            var merged: [String]?
            if !cleanEmails.isEmpty {
                let existing = (try? await GoogleCalendarAPI.eventAttendees(
                    eventID: located.eventID, calendarID: located.calendarID, token: token)) ?? []
                var set = existing
                for email in cleanEmails where !set.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                    set.append(email)
                }
                merged = set
            }
            try await GoogleCalendarAPI.patchEvent(
                eventID: located.eventID, calendarID: located.calendarID,
                attendees: merged, addMeet: addMeet, token: token
            )
            var note = "Google: "
            if !cleanEmails.isEmpty { note += "guests invited" }
            if addMeet { note += cleanEmails.isEmpty ? "Meet link added" : " + Meet link added" }
            appState.toast = note
        } catch {
            fallback(event: event, emails: cleanEmails, appState: appState,
                     reason: error.localizedDescription)
        }
    }

    /// RSVP from the calendar. Google-calendar events only (EventKit has no
    /// public RSVP API, so other accounts show a toast explaining that).
    static func respond(event: EKEvent, status: String, appState: AppState) async {
        guard let token = await GoogleAuth.shared.validToken() else {
            appState.toast = "RSVP needs Google connected (Settings ⌘,)"
            return
        }
        do {
            guard let located = try await locateEvent(event: event, token: token) else {
                appState.toast = "Event not found on the connected Google account"
                return
            }
            try await GoogleCalendarAPI.respond(eventID: located.eventID, calendarID: located.calendarID, status: status, token: token)
            let label = ["accepted": "Going", "tentative": "Maybe", "declined": "Not going"][status] ?? status
            appState.toast = "RSVP sent: \(label)"
        } catch {
            appState.toast = "RSVP failed — \(error.localizedDescription)"
        }
    }

    private static func fallback(event: EKEvent, emails: [String], appState: AppState, reason: String) {
        if emails.isEmpty {
            appState.toast = reason
            return
        }
        Invites.send(event: event, emails: emails)
        appState.toast = "\(reason) — sent .ics email invite instead"
    }

    static func clearCache() {
        cachedCalendars = nil
    }

    /// Dump Google-lookup diagnostics for upcoming attendee events to a file.
    static func runDiagnostics(store: CalendarStore, appState: AppState) async {
        var lines: [String] = ["Fork Calendar Google diagnostics — \(Date())"]
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("forkcal-google-diag.txt")
        defer {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            appState.toast = "Diagnostics written"
        }
        guard let token = await GoogleAuth.shared.validToken() else {
            lines.append("NO TOKEN — not connected")
            return
        }
        lines.append("token: ok")
        do {
            let calendars = try await GoogleCalendarAPI.calendarList(token: token)
            lines.append("google calendars:")
            for cal in calendars {
                lines.append("  \(cal.summary) | id=\(cal.id) | role=\(cal.accessRole ?? "?")")
            }
            let now = Date()
            let candidates = store.events
                .filter { $0.attendees?.isEmpty == false && ($0.startDate ?? now) > now.addingTimeInterval(-7 * 86400) }
                .prefix(5)
            lines.append("candidate events with attendees: \(candidates.count)")
            for event in candidates {
                lines.append("EVENT \"\(event.title ?? "?")\"")
                lines.append("  ekCalendar=\(event.calendar?.title ?? "?") source=\(event.calendar?.source?.title ?? "?")")
                lines.append("  externalID=\(event.calendarItemExternalIdentifier ?? "nil")")
                lines.append("  eventIdentifier=\(event.eventIdentifier ?? "nil")")
                let uids = uidCandidates(for: event)
                lines.append("  uid candidates: \(uids)")
                var hits = 0
                for cal in calendars {
                    for uid in uids {
                        do {
                            if let found = try await GoogleCalendarAPI.findEventID(iCalUID: uid, calendarID: cal.id, token: token) {
                                lines.append("  FOUND in \(cal.summary) via \(uid): eventID=\(found)")
                                hits += 1
                            }
                        } catch {
                            lines.append("  lookup error in \(cal.summary): \(error.localizedDescription)")
                        }
                    }
                    if hits == 0, let title = event.title, let start = event.startDate,
                       let found = ((try? await GoogleCalendarAPI.findEventIDByTime(title: title, start: start, calendarID: cal.id, token: token)) ?? nil) {
                        lines.append("  FOUND by time+title in \(cal.summary): eventID=\(found)")
                        hits += 1
                    }
                }
                if hits == 0 { lines.append("  NOT FOUND in any calendar") }
            }
        } catch {
            lines.append("calendarList error: \(error.localizedDescription)")
        }
    }
}
