import SwiftUI

@main
struct ForkCalendarApp: App {
    @StateObject private var store = CalendarStore()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Fork Calendar") {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Event") { appState.newEvent(store: store) }
                    .keyboardShortcut("n", modifiers: [.command])
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
            }
        }
    }
}
