import SwiftUI
import EventKit

struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let action: () -> Void
}

struct CommandPalette: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        PaletteBody(model: appState.palette)
    }
}

private struct PaletteBody: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @ObservedObject var model: PaletteModel
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        let items = buildItems()
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { appState.paletteOpen = false }
            card(items: items)
        }
        .onAppear {
            model.reset()
            focused = true
            model.itemCount = items.count
        }
        .onChange(of: model.query) {
            model.index = 0
        }
        .onChange(of: items.count) {
            model.itemCount = items.count
        }
        .onChange(of: model.confirmTick) {
            let current = buildItems()
            guard current.indices.contains(model.index) else { return }
            appState.paletteOpen = false
            current[model.index].action()
        }
    }

    private func card(items: [PaletteItem]) -> some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList(items: items)
            Divider()
            footer
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .padding(.top, 80)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search events or type a command…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
        }
        .padding(14)
    }

    private func resultsList(items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        PaletteRow(item: item, selected: i == model.index)
                            .id(i)
                            .onTapGesture {
                                appState.paletteOpen = false
                                item.action()
                            }
                            .onHover2 { _ in model.index = i }
                    }
                    if items.isEmpty {
                        Text("No results")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
            .onChange(of: model.index) {
                proxy.scrollTo(model.index)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("↑↓ navigate")
            Text("↩ select")
            Text("esc close")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func buildItems() -> [PaletteItem] {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        var items: [PaletteItem] = []

        // Natural-language quick add ("Lunch with Amy tomorrow 1pm")
        if let parsed = QuickAdd.parse(q, defaultDurationMinutes: appState.settings.defaultDuration) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            items.append(PaletteItem(
                title: "Create “\(parsed.title)”",
                subtitle: "\(f.string(from: parsed.start)) – \(Fmt.time.string(from: parsed.end))",
                icon: "plus.circle.fill",
                shortcut: "↩"
            ) {
                appState.newEvent(store: store, start: parsed.start, end: parsed.end, title: parsed.title)
            })
        }

        // "Go to date" natural entry
        if let date = parseDate(q) {
            let f = DateFormatter()
            f.dateStyle = .full
            items.append(PaletteItem(title: "Go to \(f.string(from: date))", subtitle: nil, icon: "arrow.right.circle", shortcut: nil) {
                appState.goTo(date)
            })
        }

        // Commands
        let commands: [PaletteItem] = [
            PaletteItem(title: "Go to today", subtitle: nil, icon: "calendar", shortcut: "T") { appState.goToToday() },
            PaletteItem(title: "New event", subtitle: nil, icon: "plus", shortcut: "C") { appState.newEvent(store: store) },
            PaletteItem(title: "Day view", subtitle: nil, icon: "rectangle", shortcut: "D") { appState.viewMode = .day },
            PaletteItem(title: "Week view", subtitle: nil, icon: "rectangle.split.3x1", shortcut: "W") { appState.viewMode = .week },
            PaletteItem(title: "Month view", subtitle: nil, icon: "square.grid.3x3", shortcut: "M") { appState.viewMode = .month },
            PaletteItem(title: "Year view", subtitle: nil, icon: "square.grid.4x3.fill", shortcut: "Y") { appState.viewMode = .year },
            PaletteItem(title: "Share availability", subtitle: nil, icon: "square.and.arrow.up.on.square", shortcut: "S") { appState.toggleAvailabilityMode() },
            PaletteItem(title: "Undo", subtitle: nil, icon: "arrow.uturn.backward", shortcut: "⌘Z") { store.undo() },
        ]
        if q.isEmpty {
            items.append(contentsOf: commands)
        } else {
            items.append(contentsOf: commands.filter { $0.title.localizedCaseInsensitiveContains(q) })
        }

        // Event search
        if q.count >= 2 {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            for event in store.searchEvents(q).prefix(12) {
                items.append(PaletteItem(
                    title: event.title ?? "Untitled",
                    subtitle: f.string(from: event.startDate) + (event.calendar.map { " · \($0.title)" } ?? ""),
                    icon: "calendar.day.timeline.left",
                    shortcut: nil
                ) {
                    appState.goTo(event.startDate)
                    if appState.viewMode == .month { appState.viewMode = .week }
                    appState.select(event)
                })
            }
        }
        return items
    }

    private func parseDate(_ q: String) -> Date? {
        guard !q.isEmpty else { return nil }
        let cal = appState.calendar
        let lower = q.lowercased()
        switch lower {
        case "today": return Date()
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: Date())
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: Date())
        case "next week": return cal.date(byAdding: .weekOfYear, value: 1, to: Date())
        default: break
        }
        // Weekday name → next occurrence
        let symbols = cal.weekdaySymbols.map { $0.lowercased() }
        if let idx = symbols.firstIndex(where: { $0.hasPrefix(lower) && lower.count >= 3 }) {
            let target = idx + 1
            for offset in 1...7 {
                if let d = cal.date(byAdding: .day, value: offset, to: Date()),
                   cal.component(.weekday, from: d) == target {
                    return d
                }
            }
        }
        for format in ["M/d/yyyy", "M/d", "MMM d", "MMMM d", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = format
            if let d = f.date(from: q) {
                var comps = cal.dateComponents([.month, .day], from: d)
                comps.year = format.contains("y") ? cal.component(.year, from: d) : cal.component(.year, from: Date())
                return cal.date(from: comps)
            }
        }
        return nil
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
    }
}

private extension View {
    /// onHover that no-ops on iOS.
    @ViewBuilder
    func onHover2(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        onHover { if $0 { action(true) } }
        #else
        self
        #endif
    }
}
