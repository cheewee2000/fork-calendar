import Foundation
import EventKit

enum GoogleAPIError: Error {
    case http(Int, String)
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
        guard let uid = event.calendarItemExternalIdentifier,
              let calendarTitle = event.calendar?.title else {
            fallback(event: event, emails: cleanEmails, appState: appState, reason: "No event UID yet")
            return
        }
        do {
            if cachedCalendars == nil {
                cachedCalendars = try await GoogleCalendarAPI.calendarList(token: token)
            }
            guard let gcal = (cachedCalendars ?? []).first(where: {
                $0.summary.caseInsensitiveCompare(calendarTitle) == .orderedSame || $0.id == calendarTitle
            }) else {
                fallback(event: event, emails: cleanEmails, appState: appState,
                         reason: "“\(calendarTitle)” isn't a calendar on the connected Google account")
                return
            }
            // The CalDAV push to Google may lag a few seconds for new events
            var eventID: String?
            for _ in 0..<8 {
                eventID = try await GoogleCalendarAPI.findEventID(iCalUID: uid, calendarID: gcal.id, token: token)
                if eventID != nil { break }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            guard let eventID else {
                fallback(event: event, emails: cleanEmails, appState: appState,
                         reason: "Event hasn't synced to Google yet")
                return
            }
            var merged: [String]?
            if !cleanEmails.isEmpty {
                let existing = (try? await GoogleCalendarAPI.eventAttendees(
                    eventID: eventID, calendarID: gcal.id, token: token)) ?? []
                var set = existing
                for email in cleanEmails where !set.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                    set.append(email)
                }
                merged = set
            }
            try await GoogleCalendarAPI.patchEvent(
                eventID: eventID, calendarID: gcal.id,
                attendees: merged, addMeet: addMeet, token: token
            )
            var note = "Google: "
            if !cleanEmails.isEmpty { note += "guests invited" }
            if addMeet { note += cleanEmails.isEmpty ? "Meet link added" : " + Meet link added" }
            appState.toast = note
        } catch {
            fallback(event: event, emails: cleanEmails, appState: appState,
                     reason: "Google error — \((error as? GoogleAPIError).map { String(describing: $0).prefix(80) } ?? "\(error.localizedDescription)")")
        }
    }

    /// RSVP from the calendar. Google-calendar events only (EventKit has no
    /// public RSVP API, so other accounts show a toast explaining that).
    static func respond(event: EKEvent, status: String, appState: AppState) async {
        guard let token = await GoogleAuth.shared.validToken() else {
            appState.toast = "RSVP needs Google connected (Settings ⌘,)"
            return
        }
        guard let uid = event.calendarItemExternalIdentifier,
              let calendarTitle = event.calendar?.title else {
            appState.toast = "Can't identify this event on Google"
            return
        }
        do {
            if cachedCalendars == nil {
                cachedCalendars = try await GoogleCalendarAPI.calendarList(token: token)
            }
            guard let gcal = (cachedCalendars ?? []).first(where: {
                $0.summary.caseInsensitiveCompare(calendarTitle) == .orderedSame || $0.id == calendarTitle
            }) else {
                appState.toast = "RSVP works on connected Google calendars only"
                return
            }
            guard let eventID = try await GoogleCalendarAPI.findEventID(iCalUID: uid, calendarID: gcal.id, token: token) else {
                appState.toast = "Event not found on Google yet"
                return
            }
            try await GoogleCalendarAPI.respond(eventID: eventID, calendarID: gcal.id, status: status, token: token)
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
}
