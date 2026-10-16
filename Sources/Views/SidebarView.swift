import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var accounts = AccountManager.shared
    @State private var showSettings = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private func needsReauth(_ source: String) -> Bool {
        accounts.accounts.first(where: { $0.email == source })?.needsReauth == true
    }

    private var reauthAccounts: [GoogleAccount] { accounts.accounts.filter(\.needsReauth) }

    /// "OFFLINE", "3 QUEUED", "SIGN IN: cw@cwandt.com", or joined with " · ".
    private var offlineStatus: String {
        var parts: [String] = []
        if store.isOffline { parts.append("OFFLINE") }
        if store.pendingCount > 0 { parts.append("\(store.pendingCount) QUEUED") }
        for a in reauthAccounts { parts.append("SIGN IN: \(a.email)") }
        return parts.joined(separator: " · ")
    }

    private func openSettingsUI() {
        #if os(macOS)
        openSettings()
        #else
        showSettings = true
        #endif
    }

    /// Persist a drag reorder within one account section: the saved order is
    /// the full sidebar sequence with that section's new arrangement in place.
    private func moveCalendars(in group: (source: String, calendars: [CalCalendar]), from: IndexSet, to: Int) {
        var cals = group.calendars
        cals.move(fromOffsets: from, toOffset: to)
        var order: [String] = []
        for g in store.calendarsBySource {
            order += (g.source == group.source ? cals : g.calendars).map(\.calendarIdentifier)
        }
        settings.calendarOrder = order
        store.invalidateSidebarRank()
    }

    var body: some View {
        List {
            Section {
                MiniMonthView()
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
                    .listRowSeparator(.hidden)
            }
            ForEach(store.calendarsBySource, id: \.source) { group in
                Section {
                    ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                        CalendarRow(cal: cal)
                    }
                    .onMove { from, to in
                        moveCalendars(in: group, from: from, to: to)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Text(group.source.uppercased())
                            .font(CWT.ui(10))
                            .tracking(0.6)
                            .foregroundStyle(CWT.inkSoft)
                        if needsReauth(group.source) {
                            Button {
                                openSettingsUI()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("SIGN IN AGAIN")
                                        .kerning(0.4)
                                }
                                .font(CWT.ui(10))
                                .foregroundStyle(CWT.signalOrange)
                            }
                            .buttonStyle(.plain)
                            .help("This account's sign-in expired — tap to open Settings")
                        }
                    }
                }
            }
        }
        .navigationTitle("Fork Calendar")
        #if os(iOS)
        // Programmatic push: a NavigationLink inside a List's safeAreaInset
        // doesn't reliably activate on iOS, so the gear drives this instead.
        .navigationDestination(isPresented: $showSettings) {
            SettingsView().navigationTitle("Settings")
        }
        #endif
        .safeAreaInset(edge: .bottom) {
            // CW&T ID label: the codename is the logo.
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    // The per-account "SIGN IN AGAIN" header only exists once that account has
                    // cached calendars; this pill covers a dead token on a fresh import.
                    if store.isOffline || store.pendingCount > 0 || !reauthAccounts.isEmpty {
                        Button {
                            if reauthAccounts.isEmpty { store.refresh() } else { openSettingsUI() }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: !reauthAccounts.isEmpty ? "exclamationmark.triangle.fill" : store.isOffline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                                Text(offlineStatus)
                                    .kerning(0.4)
                            }
                            .font(CWT.ui(10))
                            .foregroundStyle(CWT.signalOrange)
                        }
                        .buttonStyle(.plain)
                        .help("Changes made offline sync automatically when you're back online — tap to retry now")
                        .padding(.bottom, 3)
                    }
                    Text("CWT_STE0GW1_2607")
                        .font(CWT.ui(10))
                        .kerning(0.5)
                        .foregroundStyle(CWT.inkSoft)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")")
                        .font(CWT.ui(10))
                        .foregroundStyle(CWT.inkFaint)
                }
                Spacer()
                #if os(macOS)
                SettingsLink {
                    Image(systemName: "gearshape").font(CWT.ui(12)).foregroundStyle(CWT.inkSoft)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Accounts & settings (⌘,)")
                .accessibilityLabel("Accounts & settings")
                #else
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape").font(CWT.ui(15)).foregroundStyle(CWT.inkSoft)
                        // Finger-sized target — the bare glyph is ~15pt.
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Accounts & settings")
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

struct CalendarRow: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var settings: AppSettings
    let cal: CalCalendar
    @State private var showColorPicker = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggle(cal)
            } label: {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(cal.displayColor.opacity(store.isVisible(cal) ? 1 : 0.25))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if store.isVisible(cal) {
                                Image(systemName: "checkmark")
                                    .font(CWT.ui(9))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(cal.title)
                        .font(CWT.ui(13))
                        .foregroundStyle(store.isVisible(cal) ? AnyShapeStyle(CWT.ink) : AnyShapeStyle(CWT.inkSoft))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                // HIG ≥24pt target: the whole row toggles, not just the label.
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                showColorPicker = true
            } label: {
                Image(systemName: "paintpalette")
                    .font(CWT.ui(11))
                    .foregroundStyle(CWT.inkSoft)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || showColorPicker ? 1 : 0)
            .help("Change color")
            .accessibilityLabel("Change color")
        }
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .contextMenu {
            Button("Change color…") { showColorPicker = true }
        }
        .popover(isPresented: $showColorPicker) {
            CalendarColorPicker(cal: cal)
                .environmentObject(settings)
        }
    }
}

struct CalendarColorPicker: View {
    @EnvironmentObject var settings: AppSettings
    let cal: CalCalendar
    @State private var custom: Color = .blue

    private static let presets = [
        "E5484D", "F76B15", "FFB224", "46A758", "12A594", "0091FF",
        "3E63DD", "6E56CF", "AB4ABA", "E93D82", "8D8D8D", "5B5BD6",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cal.title)
                .font(CWT.ui(11))
                .lineLimit(1)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.presets, id: \.self) { hex in
                    Button {
                        settings.calendarColors[cal.calendarIdentifier] = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 22, height: 22)
                            .overlay {
                                if settings.calendarColors[cal.calendarIdentifier] == hex {
                                    Image(systemName: "checkmark")
                                        .font(CWT.ui(10))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                .font(CWT.ui(11))
                .onChange(of: custom) {
                    if let hex = custom.hexString {
                        settings.calendarColors[cal.calendarIdentifier] = hex
                    }
                }
            Button("Reset to account color") {
                settings.calendarColors.removeValue(forKey: cal.calendarIdentifier)
            }
            .font(CWT.ui(11))
            .disabled(settings.calendarColors[cal.calendarIdentifier] == nil)
        }
        .padding(12)
        .frame(width: 210)
        .onAppear { custom = cal.displayColor }
    }
}

struct MiniMonthView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let cal = appState.calendar
        VStack(spacing: 6) {
            HStack {
                Text(Fmt.monthYear.string(from: appState.currentDate))
                    .font(CWT.ui(11))
                Spacer()
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: -1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.left").font(CWT.ui(10))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Previous month")
                .accessibilityLabel("Previous month")
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: 1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.right").font(CWT.ui(10))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Next month")
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(CWT.ui(10))
                        .foregroundStyle(CWT.inkSoft)
                }
                ForEach(Array(cal.monthGrid(for: appState.currentDate).enumerated()), id: \.offset) { _, day in
                    let isToday = day.isSameDay(as: Date(), calendar: cal)
                    let isSelected = day.isSameDay(as: appState.currentDate, calendar: cal)
                    let inMonth = cal.isDate(day, equalTo: appState.currentDate, toGranularity: .month)
                    Text(Fmt.dayNum.string(from: day))
                        .font(CWT.ui(11))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if isSelected {
                                Rectangle().fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .foregroundStyle(isToday ? CWT.signalRed : inMonth ? Color.primary : CWT.inkSoft.opacity(0.5))
                        .contentShape(Rectangle())
                        .onTapGesture { appState.currentDate = day }
                }
            }
        }
    }
}
