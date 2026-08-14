import Foundation
import EventKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sends event invitations as an emailed .ics attachment (EventKit has no
/// public API for adding attendees directly).
enum Invites {
    static func send(event: EKEvent, emails: [String]) {
        let clean = emails
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        guard !clean.isEmpty else { return }
        let ics = icsString(event: event, attendees: clean)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-\(UUID().uuidString.prefix(8)).ics")
        do {
            try ics.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("ICS write failed: \(error)")
            return
        }
        let title = event.title ?? "Event"
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = event.isAllDay ? .none : .short
        let body = "You're invited: \(title)\n\(df.string(from: event.startDate ?? Date()))\n\nOpen the attached invite to add it to your calendar and RSVP."
        #if os(macOS)
        let service = NSSharingService(named: .composeEmail)
        service?.recipients = clean
        service?.subject = "Invitation: \(title)"
        service?.perform(withItems: [body, fileURL])
        #else
        presentShareSheet(items: [body, fileURL])
        #endif
    }

    private static func icsString(event: EKEvent, attendees: [String]) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyyMMdd"

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        let uid = event.eventIdentifier ?? UUID().uuidString
        let start = event.startDate ?? Date()
        let end = event.endDate ?? start.addingTimeInterval(3600)
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//CW&T//Fork Calendar//EN",
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(fmt.string(from: Date()))",
        ]
        if event.isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(dayFmt.string(from: start))")
            lines.append("DTEND;VALUE=DATE:\(dayFmt.string(from: end.addingTimeInterval(86400)))")
        } else {
            lines.append("DTSTART:\(fmt.string(from: start))")
            lines.append("DTEND:\(fmt.string(from: end))")
        }
        lines.append("SUMMARY:\(esc(event.title ?? "Event"))")
        if let location = event.location, !location.isEmpty {
            lines.append("LOCATION:\(esc(location))")
        }
        if let notes = event.notes, !notes.isEmpty {
            lines.append("DESCRIPTION:\(esc(notes))")
        }
        if let url = event.url {
            lines.append("URL:\(url.absoluteString)")
        }
        for email in attendees {
            lines.append("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:\(email)")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    #if os(iOS)
    private static func presentShareSheet(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let avc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        avc.popoverPresentationController?.sourceView = top.view
        top.present(avc, animated: true)
    }
    #endif
}
