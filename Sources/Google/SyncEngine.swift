import Foundation
import Combine

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
    /// Called after any change to calendars/records (store rebuilds views).
    var onChange: (() -> Void)?

    private let accounts = AccountManager.shared
    private var saveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init() {
        let now = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        window = SyncEngine.defaultWindow(around: now)
        load()
        accounts.$accounts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.accountsChanged(list) }
            .store(in: &bag)
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
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: WidgetBridge.suiteName) {
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
            cacheRevision: SyncEngine.cacheRevision
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

    /// Await a full pass (used by ⌘R and the launch sync).
    func syncAllAndWait() async {
        await withCheckedContinuation { cont in
            syncAll { cont.resume() }
        }
    }

    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        await accounts.resolvePlaceholders()
        var errors: [String] = []
        for account in accounts.enabledAccounts {
            do {
                try await syncAccount(account)
            } catch {
                errors.append("\(account.email): \(error.localizedDescription)")
            }
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.isEmpty { lastSync = Date() }
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

    /// Incremental sync for one calendar; falls back to a full windowed
    /// listing when there's no token or Google says it expired.
    func syncCalendar(_ cal: CalCalendar, token: String) async throws {
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

    func masterRules(calendarKey: String, masterID: String) -> [String]? {
        masters[calendarKey + "|" + masterID]
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
        syncTokens = [:]
        masters = [:]
        lastSync = nil
        saveNow()
        onChange?()
    }
}
