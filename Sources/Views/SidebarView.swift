import SwiftUI
import EventKit

struct SidebarView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section {
                MiniMonthView()
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
                    .listRowSeparator(.hidden)
            }
            ForEach(store.calendarsBySource, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                        CalendarRow(cal: cal)
                    }
                }
            }
        }
        .navigationTitle("Fork Calendar")
        .safeAreaInset(edge: .bottom) {
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }
}

struct CalendarRow: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var settings: AppSettings
    let cal: EKCalendar
    @State private var showColorPicker = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggle(cal)
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(cal.displayColor.opacity(store.isVisible(cal) ? 1 : 0.25))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if store.isVisible(cal) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text(cal.title)
                        .foregroundStyle(store.isVisible(cal) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                showColorPicker = true
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || showColorPicker ? 1 : 0)
            .help("Change color")
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
    let cal: EKCalendar
    @State private var custom: Color = .blue

    private static let presets = [
        "E5484D", "F76B15", "FFB224", "46A758", "12A594", "0091FF",
        "3E63DD", "6E56CF", "AB4ABA", "E93D82", "8D8D8D", "5B5BD6",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cal.title)
                .font(.caption.weight(.semibold))
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
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                .font(.caption)
                .onChange(of: custom) {
                    if let hex = custom.hexString {
                        settings.calendarColors[cal.calendarIdentifier] = hex
                    }
                }
            Button("Reset to account color") {
                settings.calendarColors.removeValue(forKey: cal.calendarIdentifier)
            }
            .font(.caption)
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
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: -1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.left").font(.caption2)
                }
                Button {
                    appState.currentDate = cal.date(byAdding: .month, value: 1, to: appState.currentDate) ?? appState.currentDate
                } label: {
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(cal.orderedVeryShortWeekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cal.monthGrid(for: appState.currentDate).enumerated()), id: \.offset) { _, day in
                    let isToday = day.isSameDay(as: Date(), calendar: cal)
                    let isSelected = day.isSameDay(as: appState.currentDate, calendar: cal)
                    let inMonth = cal.isDate(day, equalTo: appState.currentDate, toGranularity: .month)
                    Text(Fmt.dayNum.string(from: day))
                        .font(.system(size: 10, weight: isToday ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                            }
                        }
                        .foregroundStyle(isToday ? Color.red : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                        .contentShape(Rectangle())
                        .onTapGesture { appState.currentDate = day }
                }
            }
        }
    }
}
