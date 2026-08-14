import SwiftUI
import EventKit
#if os(iOS)
import UIKit
#endif

struct RootView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            CalendarDetailView()
        }
        .task { await store.requestAccess() }
        .onChange(of: appState.currentDate) { fetchVisible() }
        .onChange(of: appState.viewMode) { fetchVisible() }
        .onChange(of: store.accessState) { fetchVisible() }
        .sheet(item: $appState.editorContext) { context in
            EventEditorView(context: context)
                .environmentObject(store)
                .environmentObject(appState)
        }
    }

    private func fetchVisible() {
        let cal = appState.calendar
        var interval: DateInterval?
        switch appState.viewMode {
        case .day:
            interval = cal.dateInterval(of: .day, for: appState.currentDate)
        case .week:
            interval = cal.dateInterval(of: .weekOfYear, for: appState.currentDate)
        case .month:
            let days = cal.monthGrid(for: appState.currentDate)
            if let first = days.first, let last = days.last {
                interval = DateInterval(start: first, end: cal.date(byAdding: .day, value: 1, to: last) ?? last)
            }
        }
        if let interval { store.ensureFetched(interval) }
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
            } else {
                switch appState.viewMode {
                case .day:
                    TimeGridView(days: [appState.currentDate])
                case .week:
                    TimeGridView(days: appState.calendar.week(containing: appState.currentDate))
                case .month:
                    MonthView()
                }
            }
        }
        .onAppear {
            #if os(iOS)
            if !didSetInitialMode, sizeClass == .compact {
                appState.viewMode = .day
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
        HStack(spacing: 12) {
            Text(Fmt.monthYear.string(from: appState.currentDate))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Button { appState.step(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                Button("Today") { appState.goToToday() }
                Button { appState.step(1) } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Picker("View", selection: $appState.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            Button {
                appState.newEvent(store: store)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.accessState != .granted)
            .help("New event (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
