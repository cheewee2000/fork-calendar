import Combine
import Foundation

/// Bridge to invoice.cwandt.com: lists invoices and appends a calendar event
/// as a billable line item on a draft. Auth is the site's cookie session,
/// opened with a signed-in @cwandt.com account's Google token; URLSession's
/// shared cookie jar keeps it (30 days).
@MainActor
final class InvoiceLink: ObservableObject {
    static let shared = InvoiceLink()
    private static let base = URL(string: "https://invoice.cwandt.com/api/")!

    struct Draft: Identifiable {
        let id: String
        let client: String
        let hours: Double
    }

    @Published var drafts: [Draft] = []
    /// Google event ids already on any invoice (drawn with a $ in the grid).
    @Published var billed: Set<String> = []
    @Published var error: String?

    struct Err: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }

    private init() {
        Task { await refresh() }
    }

    func refresh() async {
        do {
            async let inv = send("GET", "invoices")
            async let cl = send("GET", "clients")
            let clients = try await cl as? [String: [String: Any]] ?? [:]
            let list = try await inv as? [[String: Any]] ?? []
            drafts = list.filter { $0["status"] as? String == "draft" }.map { d in
                let code = d["clientCode"] as? String ?? ""
                return Draft(id: d["id"] as? String ?? "",
                             client: clients[code]?["name"] as? String ?? code,
                             hours: d["subtotalHours"] as? Double ?? 0)
            }
            billed = Set(list.flatMap { ($0["lineItems"] as? [[String: Any]] ?? []).compactMap { $0["eventId"] as? String } })
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Append `event` to the draft as a line item (hours × the invoice's rate),
    /// the same shape the web editor's calendar import writes.
    func bill(_ event: CalEvent, to draft: Draft) async throws {
        // Re-read first so line items edited in the browser since `refresh` survive.
        guard var inv = try await send("GET", "invoices/\(draft.id)") as? [String: Any] else { throw Err("Invoice \(draft.id) not found") }
        var items = inv["lineItems"] as? [[String: Any]] ?? []
        let hours = event.isAllDay ? 0 : (event.endDate.timeIntervalSince(event.startDate) / 3600 * 4).rounded() / 4
        let rate = inv["hourlyRate"] as? Double ?? 0
        var item: [String: Any] = [
            "date": Self.ymd.string(from: event.startDate),
            "description": event.title ?? "",
            "hours": hours,
            "bill": (hours * rate * 100).rounded() / 100,
            "expenses": 0,
            "eventId": event.id,
        ]
        if !event.isAllDay {
            item["start"] = Self.hm.string(from: event.startDate)
            item["end"] = Self.hm.string(from: event.endDate)
        }
        // Fill the editor's first padded blank row, else append.
        if let i = items.firstIndex(where: { r in
            ["date", "description"].allSatisfy { (r[$0] as? String ?? "").isEmpty }
                && ["hours", "bill", "expenses"].allSatisfy { (r[$0] as? Double ?? 0) == 0 }
        }) { items[i] = item } else { items.append(item) }
        inv["lineItems"] = items
        _ = try await send("PUT", "invoices/\(draft.id)", body: inv)
        billed.insert(event.id)
        await refresh()
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil, retry: Bool = true) async throws -> Any {
        var req = URLRequest(url: URL(string: path, relativeTo: Self.base)!)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry {
            try await login()
            return try await send(method, path, body: body, retry: false)
        }
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            throw Err((json as? [String: Any])?["error"] as? String ?? "invoice.cwandt.com: HTTP \(code)")
        }
        guard let json else { throw Err("invoice.cwandt.com: bad JSON") }
        return json
    }

    private func login() async throws {
        guard let acct = AccountManager.shared.accounts.first(where: { $0.email.hasSuffix("@cwandt.com") }) else {
            throw Err("Sign in to a @cwandt.com Google account (Settings ⌘,) to bill events")
        }
        let token = try await AccountManager.shared.validToken(for: acct.email)
        _ = try await send("POST", "session/login", body: ["access_token": token], retry: false)
    }

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()
}
