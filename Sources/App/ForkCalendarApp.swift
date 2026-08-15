import SwiftUI

@main
struct ForkCalendarApp: App {
    @StateObject private var store = CalendarStore()
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("Fork Calendar", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(settings)
                .font(CWT.mono(12))
                .tint(CWT.ink)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 840)
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Event") { appState.newEvent(store: store) }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Search & Commands") { appState.paletteOpen.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    appState.columnVisibility = appState.columnVisibility == .detailOnly ? .all : .detailOnly
                }
                .keyboardShortcut("\\", modifiers: [.command])
            }
            CommandMenu("Go") {
                Button("Today") { appState.goToToday() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("Previous") { appState.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next") { appState.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("Day") { appState.viewMode = .day }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Week") { appState.viewMode = .week }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Month") { appState.viewMode = .month }
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
                .tint(CWT.ink)
        }
        #endif
    }
}
