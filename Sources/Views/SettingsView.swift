import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: CalendarStore
    @ObservedObject private var accounts = AccountManager.shared
    @State private var transferStatus = ""

    private static let timeZones = AppSettings.curatedTimeZones

    /// Selecting from the picker appends to the list, then the picker resets.
    private var addTimeZoneBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { id in
                guard !id.isEmpty, !settings.secondaryTZs.contains(id) else { return }
                settings.secondaryTZs.append(id)
            }
        )
    }

    var body: some View {
        Form {
            accountsSection
            syncSection
            notifySection
            generalSection
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        Section {
            ForEach(accounts.accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: account.needsReauth ? "exclamationmark.triangle.fill" : "person.crop.circle")
                        .foregroundStyle(account.needsReauth ? CWT.signalOrange : CWT.inkSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.email).font(CWT.mono(12))
                        if account.needsReauth {
                            Text("Needs sign-in again — \(account.reauthReason ?? "sign-in expired")")
                                .font(CWT.mono(9)).foregroundStyle(CWT.signalOrange)
                        } else if let name = account.name {
                            Text(name).font(CWT.mono(9)).foregroundStyle(CWT.inkSoft)
                        }
                    }
                    Spacer()
                    Toggle("Sync", isOn: Binding(
                        get: { account.syncEnabled },
                        set: { accounts.setSyncEnabled($0, for: account.email) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    if account.needsReauth {
                        Button("Sign in…") { Task { await accounts.addAccount() } }
                            .controlSize(.small)
                    }
                    Button(role: .destructive) {
                        accounts.remove(account.email)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(CWT.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help("Remove account")
                }
            }
            HStack {
                Button(accounts.isSigningIn ? "Waiting for Google…" : "Add Google account…") {
                    Task { await accounts.addAccount() }
                }
                .disabled(accounts.isSigningIn || effectiveClientID.isEmpty)
                Spacer()
                if !accounts.statusMessage.isEmpty {
                    Text(accounts.statusMessage)
                        .font(CWT.mono(10))
                        .foregroundStyle(CWT.inkSoft)
                        .lineLimit(2)
                }
            }
            DisclosureGroup("OAuth client") {
                TextField("Desktop client ID", text: $settings.googleClientID)
                TextField("Desktop client secret", text: $settings.googleClientSecret)
                #if os(iOS)
                TextField("iOS client ID (optional)", text: $settings.googleIOSClientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Paste setup from Mac") {
                        if let t = AppSettings.decodeSetupTransfer(Clipboard.paste()) {
                            settings.applySetupTransfer(t)
                            accounts.importAccounts(t.accounts)
                            store.hiddenCalendarIDs = Set(t.hiddenCalendarIDs)
                            transferStatus = "Imported \(t.accounts.count) account(s) — syncing…"
                            Task { await store.requestAccess() }
                        } else {
                            transferStatus = "Clipboard has no Fork Calendar setup"
                        }
                    }
                    Spacer()
                    Text(transferStatus).font(CWT.mono(10)).foregroundStyle(CWT.inkSoft)
                }
                #else
                HStack {
                    Button("Copy setup for iPhone") {
                        Clipboard.copy(settings.setupTransferString(
                            accounts: accounts.accounts, hiddenCalendarIDs: store.hiddenCalendarIDs))
                        transferStatus = "Copied (OAuth client, \(accounts.accounts.count) account(s), calendar visibility) — on the iPhone: Settings → OAuth client → Paste setup from Mac"
                    }
                    Spacer()
                    Text(transferStatus).font(CWT.mono(10)).foregroundStyle(CWT.inkSoft)
                }
                #endif
                Text("Create OAuth clients at console.cloud.google.com (APIs & Services → Credentials) in a project with the Google Calendar API enabled. macOS uses a **Desktop app** client; iOS works best with an **iOS** client for bundle ID com.cwandt.forkcalendar.app (falls back to the desktop client). Each account you add signs in through Google's own page.")
                    .font(CWT.mono(10))
                    .foregroundStyle(CWT.inkFaint)
            }
            .font(CWT.mono(12))
        } header: {
            Text("Google accounts")
        }
    }

    private var effectiveClientID: String {
        #if os(iOS)
        return settings.googleIOSClientID.isEmpty ? settings.googleClientID : settings.googleIOSClientID
        #else
        return settings.googleClientID
        #endif
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section("Sync") {
            Picker("Check for changes", selection: $settings.syncInterval) {
                Text("Manually (⌘R)").tag(0)
                Text("Every minute").tag(60)
                Text("Every 2 minutes").tag(120)
                Text("Every 5 minutes").tag(300)
                Text("Every 15 minutes").tag(900)
            }
            Toggle("Also sync when the app becomes active", isOn: $settings.syncOnActivate)
            HStack {
                Button(store.isRefreshing ? "Syncing…" : "Sync now") { store.refresh() }
                    .disabled(store.isRefreshing || store.accessState != .granted)
                Spacer()
                if let last = store.lastSync {
                    Text("Last sync \(last.formatted(date: .omitted, time: .shortened))")
                        .font(CWT.mono(10))
                        .foregroundStyle(CWT.inkSoft)
                }
            }
            Button("Clear local cache and re-download") {
                store.engine.resetCache()
                store.refresh()
            }
            .font(CWT.mono(11))
            Text("Edits you make are sent to Google immediately; this controls how often changes made elsewhere are pulled in.")
                .font(CWT.mono(10))
                .foregroundStyle(CWT.inkFaint)
        }
    }

    // MARK: - Notifications

    private var notifySection: some View {
        Section("Emails to guests & organizers") {
            Picker("When I change an event with guests", selection: $settings.guestNotifyPolicy) {
                ForEach(GuestNotifyPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            Toggle("Email the organizer when I RSVP", isOn: $settings.rsvpNotifyOrganizer)
            Text("Applies to creating, moving, editing and deleting events that have other guests, and to inviting people. Google sends the emails; nothing is sent from your Mail.")
                .font(CWT.mono(10))
                .foregroundStyle(CWT.inkFaint)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("Calendar") {
            Picker("New events go to", selection: $settings.defaultCalendarID) {
                Text("First account's primary").tag("")
                ForEach(store.writableCalendars, id: \.calendarIdentifier) { cal in
                    Text("\(cal.title) — \(cal.accountID)").tag(cal.calendarIdentifier)
                }
            }
            Picker("Start week on", selection: $settings.firstWeekday) {
                Text("System default").tag(0)
                Text("Sunday").tag(1)
                Text("Monday").tag(2)
            }
            Picker("Default event duration", selection: $settings.defaultDuration) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            Toggle("Show weekends in week view", isOn: $settings.showWeekends)
            Toggle("Show declined events", isOn: $settings.showDeclined)
            Toggle("Month view: all-day events only", isOn: $settings.monthAllDayOnly)
            TextField("Zoom personal meeting URL", text: $settings.zoomLink, prompt: Text("https://zoom.us/j/…"))
            ForEach(settings.secondaryTZs, id: \.self) { id in
                HStack {
                    Text("Time zone: \(AppSettings.timeZoneLabel(id))")
                    Spacer()
                    Button {
                        settings.secondaryTZs.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(CWT.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Add time zone", selection: addTimeZoneBinding) {
                Text("Choose…").tag("")
                ForEach(Self.timeZones.filter { !settings.secondaryTZs.contains($0) }, id: \.self) { id in
                    Text(id.replacingOccurrences(of: "_", with: " ")).tag(id)
                }
            }
        }
    }
}
