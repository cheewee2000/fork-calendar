import SwiftUI
import EventKit
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            HStack(spacing: 0) {
                CalendarDetailView()
                if !isCompact, let ctx = appState.panelContext {
                    Divider()
                    EventPanelView(context: ctx)
                        .id(ctx.id)
                        .frame(width: 320)
                }
            }
        }
        .task {
            await store.requestAccess()
            #if os(macOS)
            KeyMonitor.install(appState: appState, store: store)
            #endif
        }
        .onChange(of: appState.currentDate) { fetchVisible() }
        .onChange(of: appState.viewMode) { fetchVisible() }
        .onChange(of: store.accessState) { fetchVisible() }
        .onChange(of: store.events) { reresolveSelection() }
        .sheet(item: compactSheetBinding) { ctx in
            NavigationStack {
                EventPanelView(context: ctx, isSheet: true)
            }
        }
        .overlay {
            if appState.paletteOpen {
                CommandPalette()
            }
        }
        .overlay(alignment: .bottom) {
            if appState.availabilityMode {
                AvailabilityBar()
                    .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = appState.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(14)
                    .task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        appState.toast = nil
                    }
            }
        }
        .confirmationDialog(
            "This is a repeating event.",
            isPresented: $appState.showSpanDialog,
            titleVisibility: .visible
        ) {
            Button("This event only") { appState.resolveSpanAction(span: .thisEvent, store: store) }
            Button("This and all future events") { appState.resolveSpanAction(span: .futureEvents, store: store) }
            Button("Cancel", role: .cancel) { appState.resolveSpanAction(span: nil, store: store) }
        }
    }

    private var compactSheetBinding: Binding<EditorContext?> {
        Binding(
            get: { isCompact ? appState.panelContext : nil },
            set: { appState.panelContext = $0 }
        )
    }

    private func fetchVisible() {
        let cal = appState.calendar
        var interval: DateInterval?
        switch appState.viewMode {
        case .month:
            let days = cal.monthGrid(for: appState.currentDate)
            if let first = days.first, let last = days.last {
                interval = DateInterval(start: first, end: cal.date(byAdding: .day, value: 1, to: last) ?? last)
            }
        case .year:
            let year = cal.component(.year, from: appState.currentDate)
            if let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
               let nextJan = cal.date(from: DateComponents(year: year + 1, month: 1, day: 8)) {
                interval = DateInterval(start: cal.startOfWeek(for: jan1), end: nextJan)
            }
        default:
            let days = appState.visibleDays
            if let first = days.first, let last = days.last {
                interval = DateInterval(start: cal.startOfDay(for: first), end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last)) ?? last)
            }
        }
        if let interval { store.ensureFetched(interval) }
    }

    /// After a store refresh, re-point the open panel at the refreshed event instance.
    private func reresolveSelection() {
        guard let ctx = appState.panelContext, !ctx.isNew else { return }
        let key = eventKey(ctx.event)
        if let match = store.events.first(where: { eventKey($0) == key }), match !== ctx.event {
            appState.panelContext = EditorContext(event: match, isNew: false)
        }
    }
}

struct CalendarDetailView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var didSetInitialMode = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            if store.accessState == .denied {
                AccessDeniedView()
            } else if appState.viewMode == .month {
                MonthView()
            } else if appState.viewMode == .year {
                YearView()
            } else {
                TimeGridView(days: appState.visibleDays)
            }
        }
        .onAppear {
            #if os(iOS)
            if !didSetInitialMode, sizeClass == .compact {
                appState.viewMode = .days(3)
            }
            #endif
            didSetInitialMode = true
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text(Fmt.monthYear.string(from: appState.currentDate))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Button { appState.step(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                Button("Today") { appState.goToToday() }
                    .help("Today (T)")
                Button { appState.step(1) } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            viewMenu
            Button {
                appState.toggleAvailabilityMode()
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
            }
            .buttonStyle(appState.availabilityMode ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            .controlSize(.small)
            .help("Share availability (S)")
            Button {
                appState.paletteOpen = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Search & commands (⌘K)")
            Button {
                appState.newEvent(store: store)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.accessState != .granted)
            .help("New event (C)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var viewMenu: some View {
        Menu {
            Button { appState.viewMode = .day } label: { menuLabel("Day", "D", appState.viewMode == .day) }
            Button { appState.viewMode = .week } label: { menuLabel("Week", "W", appState.viewMode == .week) }
            Button { appState.viewMode = .month } label: { menuLabel("Month", "M", appState.viewMode == .month) }
            Button { appState.viewMode = .year } label: { menuLabel("Year", "Y", appState.viewMode == .year) }
            Divider()
            ForEach([2, 3, 4, 5], id: \.self) { n in
                Button { appState.viewMode = .days(n) } label: {
                    menuLabel("\(n) days", "\(n)", appState.viewMode == .days(n))
                }
            }
        } label: {
            Text(appState.viewMode.title)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Day (D) · Week (W) · Month (M) · 1–9 days")
    }

    @ViewBuilder
    private func menuLabel(_ title: String, _ key: String, _ selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// Type-erased button style so a style can be chosen conditionally.
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(Button($0).buttonStyle(style)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

struct AvailabilityBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.and.square.on.square.dashed")
            Text(appState.availabilitySlots.isEmpty
                 ? "Drag on the calendar to select available times"
                 : "\(appState.availabilitySlots.count) slot\(appState.availabilitySlots.count == 1 ? "" : "s") selected")
                .font(.callout)
            if !appState.availabilitySlots.isEmpty {
                Button("Copy availability") {
                    Clipboard.copy(appState.availabilityText())
                    appState.toggleAvailabilityMode()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Clear") { appState.availabilitySlots.removeAll() }
                    .controlSize(.small)
            }
            Button("Done") { appState.toggleAvailabilityMode() }
                .controlSize(.small)
                .help("Esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

struct AccessDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Calendar access is off")
                .font(.headline)
            Text("Fork Calendar needs calendar access to show your events.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                #if os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    openURL(url)
                }
                #else
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
