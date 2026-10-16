import Foundation
import Combine
import Network

/// On-disk shape of the local calendar cache.
struct CacheFile: Codable {
    var calendars: [CalCalendar] = []
    var events: [EventRecord] = []
    /// calendarKey → Google nextSyncToken
    var syncTokens: [String: String] = [:]
    /// "\(calendarKey)|\(masterID)" → RRULE lines of the series master
    var masters: [String: [String]] = [:]
    var windowStart: Date
    var windowEnd: Date
    var lastSync: Date?
    /// Bumped when cached records need a one-time full re-list to heal
    /// (a mismatch drops every sync token on load).
    var cacheRevision: Int?
    /// Writes made offline, waiting to replay (nil in pre-outbox caches).
    var pendingOps: [PendingOp]?
}

/// A server write that couldn't be sent (offline / transient failure), kept
/// until the next successful sync replays it in order.
struct PendingOp: Codable, Identifiable {
    enum Kind: String, Codable { case insert, update, delete }
    var id: String = UUID().uuidString
    var kind: Kind
    var accountID: String
    var calendarKey: String
    var googleCalendarID: String
    /// Local (`local-…`) id for inserts; server id otherwise.
    var eventID: String
    /// JSON event body: full for inserts, changed-fields patch for updates.
    var body: Data?
    var sendUpdates: String
    /// Record the views keep showing while the op waits (insert/update).
    var optimistic: EventRecord?
    /// Pre-edit server state, restored if the server rejects the op.
    var rollback: EventRecord?
    var created: Date = Date()

    static func encode(_ body: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: body)
    }

    var bodyJSON: [String: Any] {
        (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }
}

extension Error {
    /// Transient conditions (no network, expired sign-in, Google hiccups)
    /// where a queued write should wait rather than roll back.
    var isRetryableOffline: Bool {
        if let url = self as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        if let api = self as? GoogleAPIError, let code = api.statusCode,
           code >= 500 || code == 429 { return true }
        return false
    }
}

/// Keeps a local mirror of every enabled account's calendars and events,
/// using Google's incremental sync tokens. Records live in memory (keyed by
/// calendar, then event id) and persist to one JSON file; the store
/// materializes `CalEvent` objects from them.
@MainActor
final class SyncEngine: ObservableObject {
    private(set) var calendars: [CalCalendar] = []
    private(set) var records: [String: [String: EventRecord]] = [:]
    private var syncTokens: [String: String] = [:]
    private var masters: [String: [String]] = [:]
    private(set) var window: DateInterval
    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published var lastError: String?
    /// Every enabled account failed its last sync with a network-shaped error.
    @Published private(set) var isOffline = false
    /// Offline writes waiting to replay, oldest first.
    @Published private(set) var pendingOps: [PendingOp] = []
    /// Called after any change to calendars/records (store rebuilds views).
    var onChange: (() -> Void)?
    /// A replayed insert traded its local id for the server's.
    var onRemapID: ((_ old: String, _ new: String) -> Void)?
    /// A queued (offline) update reached Google: the pre-edit record and
    /// the server's result.
    var onReplayedUpdate: ((_ old: EventRecord?, _ new: EventRecord) -> Void)?

    private let accounts = AccountManager.shared
    private var saveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private let pathMonitor = NWPathMonitor()

    init() {
        let now = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        window = SyncEngine.defaultWindow(around: now)
        load()
        accounts.$accounts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.accountsChanged(list) }
            .store(in: &bag)
        // Connectivity back → replay the outbox / recover from offline.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isOffline || !self.pendingOps.isEmpty else { return }
                self.syncAll()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "forkcal.netpath", qos: .utility))
    }

    /// Bump to force a one-time full re-list on every calendar at next launch.
    static let cacheRevision = 2

    static func defaultWindow(around day: Date) -> DateInterval {
        DateInterval(start: day.addingTimeInterval(-365 * 86400), end: day.addingTimeInterval(548 * 86400))
    }

    // MARK: - Persistence

    static var cacheURL: URL {
        let fm = FileManager.default
        #if os(iOS)
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: WidgetData.suiteName) {
            return group.appendingPathComponent("cache.json")
        }
        #endif
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let folder = dir.appendingPathComponent("ForkCalendar", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cache.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: SyncEngine.cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data)
        else { return }
        calendars = file.calendars
        syncTokens = file.syncTokens
        masters = file.masters
        // Failed pushes before v0.15.28 could leave locally-edited records the
        // incremental sync never heals (the server copy never changed, so it's
        // never re-sent). One full re-list per calendar rebuilds from truth.
        if file.cacheRevision != SyncEngine.cacheRevision { syncTokens.removeAll() }
        window = DateInterval(start: file.windowStart, end: file.windowEnd)
        lastSync = file.lastSync
        pendingOps = file.pendingOps ?? []
        var dict: [String: [String: EventRecord]] = [:]
        for r in file.events { dict[r.calendarKey, default: [:]][r.id] = r }
        records = dict
        // Drop anything belonging to accounts that no longer exist
        let known = Set(accounts.accounts.map(\.email))
        calendars.removeAll { !known.contains($0.accountID) }
        for key in records.keys where !calendars.contains(where: { $0.calendarIdentifier == key }) {
            records[key] = nil
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let file = CacheFile(
            calendars: calendars,
            events: records.values.flatMap { $0.values },
            syncTokens: syncTokens,
            masters: masters,
            windowStart: window.start,
            windowEnd: window.end,
            lastSync: lastSync,
            cacheRevision: SyncEngine.cacheRevision,
            pendingOps: pendingOps
        )
        let url = SyncEngine.cacheURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Accounts

    private func accountsChanged(_ list: [GoogleAccount]) {
        let known = Set(list.map(\.email))
        let before = calendars.count
        calendars.removeAll { !known.contains($0.accountID) }
        for key in records.keys where !calendars.contains(where: { $0.calendarIdentifier == key }) {
            records[key] = nil
            syncTokens[key] = nil
        }
        pendingOps.removeAll { !known.contains($0.accountID) }
        if calendars.count != before { onChange?(); scheduleSave() }
        // A newly added account gets synced right away
        if list.contains(where: { a in !calendars.contains(where: { $0.accountID == a.email }) && a.syncEnabled && !a.needsReauth }) {
            syncAll()
        }
    }

    // MARK: - Window

    /// Make sure `interval` is inside the synced window; widening the window
    /// invalidates every sync token (the next sync is a full re-list).
    func ensureWindow(covers interval: DateInterval) {
        guard interval.start < window.start || interval.end > window.end else { return }
        var start = window.start
        var end = window.end
        if interval.start < start { start = interval.start.addingTimeInterval(-365 * 86400) }
        if interval.end > end { end = interval.end.addingTimeInterval(365 * 86400) }
        window = DateInterval(start: start, end: end)
        syncTokens.removeAll()
        syncAll()
    }

    // MARK: - Sync

    /// Sync every enabled account. Coalesces: a call during a sync schedules
    /// one more pass after it finishes.
    private var syncAgain = false

    func syncAll(completion: (() -> Void)? = nil) {
        if syncTask != nil {
            syncAgain = true
            return
        }
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSync()
            self.syncTask = nil
            completion?()
            if self.syncAgain {
                self.syncAgain = false
                self.syncAll()
            }
        }
    }


    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        await accounts.resolvePlaceholders()
        await drainOutbox()
        var errors: [String] = []
        var allOffline = true
        for account in accounts.enabledAccounts {
            do {
                try await syncAccount(account)
            } catch {
                errors.append("\(account.email): \(error.localizedDescription)")
                if !error.isRetryableOffline { allOffline = false }
            }
        }
        if errors.isEmpty {
            isOffline = false
            lastError = nil
            lastSync = Date()
        } else if allOffline {
            // No toast spam while offline — the sidebar pill shows it.
            isOffline = true
            lastError = nil
        } else {
            isOffline = false
            lastError = errors.joined(separator: "\n")
        }
        scheduleSave()
        onChange?()
    }

    private func syncAccount(_ account: GoogleAccount) async throws {
        let token = try await accounts.validToken(for: account.email)
        let list = try await GoogleCalendarAPI.calendarList(token: token)
        // Reconcile this account's calendars in place (stable object identity)
        var seen = Set<String>()
        for entry in list where entry.deleted != true {
            let key = CalCalendar.key(account: account.email, calendar: entry.id)
            seen.insert(key)
            if let existing = calendars.first(where: { $0.calendarIdentifier == key }) {
                existing.title = entry.title
                existing.colorHex = entry.backgroundColor
                existing.accessRole = entry.accessRole ?? "reader"
                existing.isPrimary = entry.primary ?? false
                existing.timeZone = entry.timeZone
            } else {
                calendars.append(CalCalendar(
                    googleID: entry.id, accountID: account.email, title: entry.title,
                    colorHex: entry.backgroundColor, accessRole: entry.accessRole ?? "reader",
                    isPrimary: entry.primary ?? false, timeZone: entry.timeZone
                ))
            }
        }
        for cal in calendars where cal.accountID == account.email && !seen.contains(cal.calendarIdentifier) {
            records[cal.calendarIdentifier] = nil
            syncTokens[cal.calendarIdentifier] = nil
        }
        calendars.removeAll { $0.accountID == account.email && !seen.contains($0.calendarIdentifier) }
        onChange?()

        let mine = calendars.filter { $0.accountID == account.email && $0.accessRole != "freeBusyReader" }
        // Calendars sync concurrently; each one's result lands on the main actor.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for cal in mine {
                group.addTask { @MainActor [weak self] in
                    try await self?.syncCalendar(cal, token: token)
                }
            }
            try await group.waitForAll()
        }
    }

    /// One listing per calendar at a time: a post-save `resync` that overlaps
    /// the timer's pass would race it — each listing snapshots `records[key]`
    /// at start and writes it back wholesale, so whichever finished last
    /// erased the other's results (a new series' instances vanished until
    /// the next pass), and its older sync token won.
    private var listings: [String: Task<Void, Error>] = [:]

    func syncCalendar(_ cal: CalCalendar, token: String) async throws {
        let key = cal.calendarIdentifier
        let previous = listings[key]
        let task = Task { @MainActor in
            _ = await previous?.result
            try await self.listCalendar(cal, token: token)
        }
        listings[key] = task
        defer { if listings[key] == task { listings[key] = nil } }
        try await task.value
    }

    /// Incremental sync for one calendar; falls back to a full windowed
    /// listing when there's no token or Google says it expired.
    private func listCalendar(_ cal: CalCalendar, token: String) async throws {
        let key = cal.calendarIdentifier
        liveListings += 1
        defer {
            liveListings -= 1
            if liveListings == 0 { localWrites.removeAll() }
        }
        var syncToken = syncTokens[key]
        var fresh: [String: EventRecord] = syncToken == nil ? [:] : (records[key] ?? [:])
        var touchedMasters = Set<String>()
        var page: String?
        while true {
            let result: GoogleCalendarAPI.EventsPage
            do {
                result = try await GoogleCalendarAPI.events(
                    calendarID: cal.googleID, token: token,
                    syncToken: syncToken, pageToken: page,
                    timeMin: syncToken == nil ? window.start : nil,
                    timeMax: syncToken == nil ? window.end : nil
                )
            } catch GoogleAPIError.syncTokenExpired {
                // Start over with a full listing
                syncToken = nil
                fresh = [:]
                page = nil
                continue
            }
            for item in result.items {
                if item.status == "cancelled" {
                    fresh[item.id] = nil
                    continue
                }
                guard var record = item.record(calendarKey: key) else { continue }
                if let masterID = record.recurringEventId {
                    touchedMasters.insert(masterID)
                    record.recurrence = masters[key + "|" + masterID]
                }
                fresh[item.id] = record
            }
            if let next = result.nextPageToken {
                page = next
            } else {
                if let token = result.nextSyncToken { syncTokens[key] = token }
                break
            }
        }
        // Replay local writes that landed while this listing was in flight:
        // `fresh` is a snapshot from before them (empty on a full re-list),
        // so the wholesale replace below would erase an event created or
        // edited mid-sync — and it would only come back on the NEXT sync.
        for w in localWrites where w.key == key {
            fresh[w.id] = w.record
        }
        // Shield outbox state the server hasn't seen yet: a full re-list
        // snapshot would show the pre-edit copy (or resurrect a deletion)
        // until the queued op finally replays.
        for op in pendingOps where op.calendarKey == key {
            switch op.kind {
            case .insert, .update:
                if let r = op.optimistic { fresh[r.id] = r }
            case .delete:
                fresh[op.eventID] = nil
            }
        }
        records[key] = fresh
        onChange?()
        // Series masters: fetch rules for any series touched in this pass
        if !touchedMasters.isEmpty {
            await fetchMasters(touchedMasters, calendar: cal, token: token)
        }
    }

    private func fetchMasters(_ ids: Set<String>, calendar cal: CalCalendar, token: String) async {
        let key = cal.calendarIdentifier
        await withTaskGroup(of: (String, [String]?).self) { group in
            for id in ids.prefix(200) {
                group.addTask {
                    let event = try? await GoogleCalendarAPI.getEvent(calendarID: cal.googleID, eventID: id, token: token)
                    return (id, event?.recurrence)
                }
            }
            for await (id, rules) in group {
                guard let rules else { continue }
                masters[key + "|" + id] = rules
            }
        }
        // Stamp the rules onto cached instances
        if var dict = records[key] {
            for (id, var r) in dict where r.recurringEventId != nil {
                r.recurrence = masters[key + "|" + r.recurringEventId!]
                dict[id] = r
            }
            records[key] = dict
        }
        onChange?()
        scheduleSave()
    }

    /// Re-sync a single calendar (after a write), quietly.
    func resync(calendarKey: String) async {
        guard let cal = calendars.first(where: { $0.calendarIdentifier == calendarKey }) else { return }
        do {
            let token = try await accounts.validToken(for: cal.accountID)
            try await syncCalendar(cal, token: token)
            scheduleSave()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Offline outbox

    /// The op currently being replayed; enqueue/cancel must not touch it.
    private var inflightOpID: String?

    /// Queue a write that couldn't reach the server, coalescing with any op
    /// already queued for the same event (one op per event id at most).
    func enqueue(_ op: PendingOp) {
        if let i = pendingOps.firstIndex(where: {
            $0.calendarKey == op.calendarKey && $0.eventID == op.eventID && $0.id != inflightOpID
        }) {
            var merged = pendingOps[i]
            switch (merged.kind, op.kind) {
            case (.insert, .delete):
                // Never reached the server — nothing to send at all.
                pendingOps.remove(at: i)
                scheduleSave()
                return
            case (.insert, _):
                // Re-saves of a still-local event carry a fresh full body.
                merged.body = op.body
                merged.optimistic = op.optimistic
                merged.sendUpdates = op.sendUpdates
            case (.update, .delete):
                merged.kind = .delete
                merged.body = nil
                merged.optimistic = nil
                merged.sendUpdates = op.sendUpdates
            case (.update, _):
                // Each patch diffs against the previous optimistic state, so
                // accumulated fields (new ones winning) equal one big patch
                // against the original server record.
                merged.body = SyncEngine.mergeBodies(merged.body, op.body)
                merged.optimistic = op.optimistic
                merged.sendUpdates = op.sendUpdates
            case (.delete, _):
                merged = op
            }
            pendingOps[i] = merged
        } else {
            pendingOps.append(op)
        }
        scheduleSave()
    }

    /// Drop a queued insert whose event was deleted before it ever synced.
    func cancelPending(eventID: String, calendarKey: String) {
        let before = pendingOps.count
        pendingOps.removeAll {
            $0.calendarKey == calendarKey && $0.eventID == eventID && $0.id != inflightOpID
        }
        if pendingOps.count != before { scheduleSave() }
    }

    /// Force the next listing of this calendar to be a full re-list (heals
    /// local state that drifted from the server while offline).
    func dropSyncToken(forKey key: String) { syncTokens[key] = nil }

    private static func mergeBodies(_ a: Data?, _ b: Data?) -> Data? {
        guard let a else { return b }
        guard let b else { return a }
        guard var base = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              let over = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any]
        else { return b }
        for (k, v) in over { base[k] = v }
        return PendingOp.encode(base)
    }

    /// Replay queued writes oldest-first. Stops at the first still-offline
    /// failure (keeping that op and everything after it); a genuine server
    /// rejection drops the op, restores the pre-edit record, and forces a
    /// full re-list so every optimistic copy heals.
    private func drainOutbox() async {
        guard !pendingOps.isEmpty else { return }
        let known = Set(accounts.accounts.map(\.email))
        pendingOps.removeAll { !known.contains($0.accountID) }
        var rejected: [String] = []
        while let op = pendingOps.first {
            do {
                let token = try await accounts.validToken(for: op.accountID)
                try await replay(op, token: token)
            } catch {
                if error.isRetryableOffline { break }
                rejected.append(error.localizedDescription)
                rollback(op)
            }
            pendingOps.removeAll { $0.id == op.id }
        }
        if !rejected.isEmpty {
            // A rejected op may have left optimistic edits (and mirrored
            // copies) the incremental sync can never re-send — re-list all.
            syncTokens.removeAll()
            lastError = "Offline change rejected — " + rejected.joined(separator: "\n")
        }
        scheduleSave()
        onChange?()
    }

    private func replay(_ op: PendingOp, token: String) async throws {
        inflightOpID = op.id
        defer { inflightOpID = nil }
        switch op.kind {
        case .insert:
            let created = try await GoogleCalendarAPI.insert(
                calendarID: op.googleCalendarID, body: op.bodyJSON,
                sendUpdates: op.sendUpdates, token: token
            )
            remove(id: op.eventID, calendarKey: op.calendarKey)
            if let record = created.record(calendarKey: op.calendarKey) {
                upsert(record)
                // Ops queued against the local id while this one was in
                // flight now target the server copy.
                for i in pendingOps.indices
                where pendingOps[i].id != op.id
                    && pendingOps[i].calendarKey == op.calendarKey
                    && pendingOps[i].eventID == op.eventID {
                    pendingOps[i].eventID = record.id
                    if pendingOps[i].kind == .insert { pendingOps[i].kind = .update }
                }
                onRemapID?(op.eventID, record.id)
            }
        case .update:
            let patched = try await GoogleCalendarAPI.patch(
                calendarID: op.googleCalendarID, eventID: op.eventID,
                body: op.bodyJSON, sendUpdates: op.sendUpdates, token: token
            )
            if var record = patched.record(calendarKey: op.calendarKey) {
                record.recurrence = record.recurrence ?? op.optimistic?.recurrence
                upsert(record)
                onReplayedUpdate?(op.rollback, record)
            }
        case .delete:
            try await GoogleCalendarAPI.delete(
                calendarID: op.googleCalendarID, eventID: op.eventID,
                sendUpdates: op.sendUpdates, token: token
            )
        }
    }

    private func rollback(_ op: PendingOp) {
        switch op.kind {
        case .insert:
            remove(id: op.eventID, calendarKey: op.calendarKey)
        case .update, .delete:
            if let old = op.rollback {
                records[old.calendarKey, default: [:]][old.id] = old
            }
        }
    }

    func setMasterRules(_ rules: [String]?, calendarKey: String, masterID: String) {
        masters[calendarKey + "|" + masterID] = rules
        if var dict = records[calendarKey] {
            for (id, var r) in dict where r.recurringEventId == masterID {
                r.recurrence = rules
                dict[id] = r
            }
            records[calendarKey] = dict
        }
    }

    // MARK: - Local mutations (optimistic; the server round-trip follows)

    /// Listing passes currently in flight. While any are live, local writes
    /// are journaled so each pass can replay them over its own snapshot —
    /// `syncCalendar` replaces `records[key]` wholesale, which would
    /// otherwise erase anything written after the listing began.
    private var liveListings = 0
    private var localWrites: [(key: String, id: String, record: EventRecord?)] = []

    func upsert(_ record: EventRecord) {
        if liveListings > 0 { localWrites.append((record.calendarKey, record.id, record)) }
        records[record.calendarKey, default: [:]][record.id] = record
        scheduleSave()
    }

    func remove(id: String, calendarKey: String) {
        if liveListings > 0 { localWrites.append((calendarKey, id, nil)) }
        records[calendarKey]?[id] = nil
        scheduleSave()
    }

    /// Drop every cached instance of a series (after deleting/truncating it).
    func removeInstances(of masterID: String, calendarKey: String, from date: Date? = nil) {
        guard var dict = records[calendarKey] else { return }
        for (id, r) in dict where r.recurringEventId == masterID {
            if let date, (r.originalStart ?? r.start) < date { continue }
            if liveListings > 0 { localWrites.append((calendarKey, id, nil)) }
            dict[id] = nil
        }
        records[calendarKey] = dict
        scheduleSave()
    }

    func record(id: String, calendarKey: String) -> EventRecord? {
        records[calendarKey]?[id]
    }

    func calendar(forKey key: String) -> CalCalendar? {
        calendars.first { $0.calendarIdentifier == key }
    }

    /// Forget everything (sign-out of all accounts / debugging).
    func resetCache() {
        calendars = []
        records = [:]
        localWrites = []
        pendingOps = []
        syncTokens = [:]
        masters = [:]
        lastSync = nil
        saveNow()
        onChange?()
    }
}
