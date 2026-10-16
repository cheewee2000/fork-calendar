import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct ForkCalendarApp: App {
    @StateObject private var store = CalendarStore()
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        // UIKit-drawn navigation bar titles don't see SwiftUI fonts.
        // CWT.helveticaNow registers the bundled Helvetica Now files first.
        if CWT.helveticaNow, let medium16 = UIFont(name: "HelveticaNowText-Medium", size: 16) {
            UINavigationBar.appearance().titleTextAttributes = [.font: medium16]
        }
        if CWT.helveticaNow, let medium26 = UIFont(name: "HelveticaNowText-Medium", size: 26) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: medium26]
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("Fork Calendar", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(settings)
                .font(CWT.ui(12))
                .tint(CWT.ink)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 840)
        // One header strip (HIG): RootView's HeaderBar is the title area.
        .windowStyle(.hiddenTitleBar)
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.syncIfDue() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Event") { appState.newEvent(store: store) }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Search & Commands") { appState.paletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Find Events…") { appState.paletteOpen = true }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Delete Event") { appState.quickDelete(store: store) }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(appState.selectedKey == nil)
                Button("Bill Event to Invoice…") { appState.billEvent() }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(appState.selectedKey == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    appState.columnVisibility = appState.columnVisibility == .detailOnly ? .all : .detailOnly
                }
                .keyboardShortcut("\\", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Calendars") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            CommandMenu("Go") {
                Button("Today") { appState.goToToday() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("Previous") { appState.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next") { appState.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("Day") { appState.setViewMode(.day) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Week") { appState.setViewMode(.week) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("9 Days") { appState.setViewMode(.days(9)) }
                    .keyboardShortcut("9", modifiers: [.command])
                Button("Month") { appState.setViewMode(.month) }
                    .keyboardShortcut("3", modifiers: [.command])
                Divider()
                Button("Share Availability") { appState.toggleAvailabilityMode() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        #if os(macOS)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(appState)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
                .tint(CWT.ink)
        }
        #endif
    }
}
