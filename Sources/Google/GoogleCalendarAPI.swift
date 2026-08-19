import Foundation

enum GoogleAPIError: LocalizedError {
    case http(Int, String)
    case syncTokenExpired
    case notFound

    var errorDescription: String? {
        switch self {
        case .syncTokenExpired: return "Sync token expired"
        case .notFound: return "Google: event not found"
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
            return "Google: \(String(message.prefix(160)))"
        }
    }

    var statusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }
}

/// Google Calendar v3 wire formats.
struct GCalendarListEntry: Decodable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String?
    let primary: Bool?
    let timeZone: String?
    let deleted: Bool?
    let hidden: Bool?

    var title: String { summaryOverride ?? summary ?? id }
}

struct GEventTime: Decodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

struct GAttendee: Decodable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let isSelf: Bool?
    let organizer: Bool?
    let optional: Bool?
    let resource: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer, optional, resource
        case isSelf = "self"
    }
}

struct GEvent: Decodable {
    struct Person: Decodable {
        let email: String?
        let displayName: String?
        let isSelf: Bool?
        enum CodingKeys: String, CodingKey { case email, displayName, isSelf = "self" }
    }
    struct Source: Decodable { let url: String?; let title: String? }

    let id: String
    let etag: String?
    let status: String?
    let iCalUID: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: GEventTime?
    let end: GEventTime?
    let recurrence: [String]?
    let recurringEventId: String?
    let originalStartTime: GEventTime?
    let attendees: [GAttendee]?
    let organizer: Person?
    let hangoutLink: String?
    let htmlLink: String?
    let updated: String?
    let colorId: String?
    let transparency: String?
    let guestsCanModify: Bool?
    let source: Source?

    /// Nil when the payload can't describe a dated event (cancelled stubs).
    func record(calendarKey: String) -> EventRecord? {
        guard let s = start, let e = end,
              let startDate = GoogleDates.parse(s), let endDate = GoogleDates.parse(e)
        else { return nil }
        let attendees = (self.attendees ?? []).compactMap { a -> CalAttendee? in
            guard let email = a.email else { return nil }
            return CalAttendee(
                email: email, displayName: a.displayName,
                responseStatus: ParticipantStatus(google: a.responseStatus),
                isSelf: a.isSelf ?? false, isOrganizer: a.organizer ?? false,
                isOptional: a.optional ?? false, isResource: a.resource ?? false
            )
        }
        return EventRecord(
            id: id,
            calendarKey: calendarKey,
            iCalUID: iCalUID,
            status: status ?? "confirmed",
            title: summary,
            notes: description,
            location: location,
            start: startDate,
            end: endDate,
            isAllDay: s.date != nil,
            timeZone: s.timeZone,
            url: source?.url,
            recurrence: recurrence,
            recurringEventId: recurringEventId,
            originalStart: originalStartTime.flatMap(GoogleDates.parse),
            attendees: attendees.isEmpty ? nil : attendees,
            organizerEmail: organizer?.email,
            organizerSelf: organizer?.isSelf ?? false,
            hangoutLink: hangoutLink,
            htmlLink: htmlLink,
            etag: etag,
            updated: updated.flatMap { GoogleDates.rfc3339.date(from: $0) ?? GoogleDates.rfc3339Plain.date(from: $0) },
            colorId: colorId,
            transparency: transparency,
            guestsCanModify: guestsCanModify ?? false
        )
    }
}

enum GoogleDates {
    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let rfc3339Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()
    static let rruleUTC: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func parse(_ t: GEventTime) -> Date? {
        if let dt = t.dateTime {
            return rfc3339.date(from: dt) ?? rfc3339Plain.date(from: dt)
        }
        if let d = t.date {
            dayFormatter.timeZone = TimeZone.autoupdatingCurrent
            return dayFormatter.date(from: d)
        }
        return nil
    }

    static func json(_ date: Date, allDay: Bool, timeZone: String?) -> [String: Any] {
        if allDay {
            dayFormatter.timeZone = TimeZone.autoupdatingCurrent
            return ["date": dayFormatter.string(from: date)]
        }
        var d: [String: Any] = ["dateTime": rfc3339Plain.string(from: date)]
        d["timeZone"] = timeZone ?? TimeZone.autoupdatingCurrent.identifier
        return d
    }

    static func iso(_ date: Date) -> String { rfc3339Plain.string(from: date) }
}

/// Thin Google Calendar REST client. Stateless; every call takes a token.
enum GoogleCalendarAPI {
    private static let base = "https://www.googleapis.com/calendar/v3"

    struct EventsPage {
        let items: [GEvent]
        let nextPageToken: String?
        let nextSyncToken: String?
    }

    static func calendarList(token: String) async throws -> [GCalendarListEntry] {
        struct ListResponse: Decodable { let items: [GCalendarListEntry]?; let nextPageToken: String? }
        var all: [GCalendarListEntry] = []
        var page: String?
        repeat {
            var url = "\(base)/users/me/calendarList?maxResults=250&showHidden=true"
            if let page { url += "&pageToken=\(page)" }
            let data = try await get(url, token: token)
            let response = try JSONDecoder().decode(ListResponse.self, from: data)
            all += response.items ?? []
            page = response.nextPageToken
        } while page != nil
        return all
    }

    /// One page of events. Pass `syncToken` for incremental sync (no time
    /// bounds allowed then); otherwise a bounded full listing.
    static func events(
        calendarID: String, token: String,
        syncToken: String?, pageToken: String?,
        timeMin: Date?, timeMax: Date?
    ) async throws -> EventsPage {
        struct Response: Decodable {
            let items: [GEvent]?
            let nextPageToken: String?
            let nextSyncToken: String?
        }
        var comps = URLComponents(string: "\(base)/calendars/\(enc(calendarID))/events")!
        var items = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        if let syncToken {
            items.append(URLQueryItem(name: "syncToken", value: syncToken))
        } else {
            if let timeMin { items.append(URLQueryItem(name: "timeMin", value: GoogleDates.iso(timeMin))) }
            if let timeMax { items.append(URLQueryItem(name: "timeMax", value: GoogleDates.iso(timeMax))) }
        }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        let data: Data
        do {
            data = try await get(comps.url!.absoluteString, token: token)
        } catch GoogleAPIError.http(410, _) {
            throw GoogleAPIError.syncTokenExpired
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return EventsPage(items: response.items ?? [], nextPageToken: response.nextPageToken, nextSyncToken: response.nextSyncToken)
    }

    static func getEvent(calendarID: String, eventID: String, token: String) async throws -> GEvent {
        let data = try await get("\(base)/calendars/\(enc(calendarID))/events/\(enc(eventID))", token: token)
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    static func insert(calendarID: String, body: [String: Any], sendUpdates: String, token: String) async throws -> GEvent {
        let url = "\(base)/calendars/\(enc(calendarID))/events?sendUpdates=\(sendUpdates)&conferenceDataVersion=1"
        let data = try await send("POST", url: url, body: body, token: token)
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    static func patch(calendarID: String, eventID: String, body: [String: Any], sendUpdates: String, token: String) async throws -> GEvent {
        let url = "\(base)/calendars/\(enc(calendarID))/events/\(enc(eventID))?sendUpdates=\(sendUpdates)&conferenceDataVersion=1"
        let data = try await send("PATCH", url: url, body: body, token: token)
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    static func delete(calendarID: String, eventID: String, sendUpdates: String, token: String) async throws {
        let url = "\(base)/calendars/\(enc(calendarID))/events/\(enc(eventID))?sendUpdates=\(sendUpdates)"
        do {
            _ = try await send("DELETE", url: url, body: nil, token: token)
        } catch GoogleAPIError.http(410, _) {
            // already gone
        } catch GoogleAPIError.notFound {
            // already gone
        }
    }

    /// Move between calendars of the same account.
    static func move(calendarID: String, eventID: String, to destination: String, sendUpdates: String, token: String) async throws -> GEvent {
        let url = "\(base)/calendars/\(enc(calendarID))/events/\(enc(eventID))/move?destination=\(enc(destination))&sendUpdates=\(sendUpdates)"
        let data = try await send("POST", url: url, body: nil, token: token)
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    // MARK: - plumbing

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private static func get(_ url: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return data
    }

    private static func send(_ method: String, url: String, body: [String: Any]?, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return data
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            if http.statusCode == 404 { throw GoogleAPIError.notFound }
            throw GoogleAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
