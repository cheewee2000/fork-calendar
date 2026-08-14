import SwiftUI
import EventKit
#if os(macOS)
import AppKit
#endif

/// Day/N-day/week timeline. Renders three "pages" (previous / current / next
/// period) in a clipped strip so trackpad side-scrolling pans smoothly into
/// the neighboring weeks before snapping.
struct TimeGridView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    let days: [Date]

    private var gutterWidth: CGFloat { settings.secondaryTimeZone == nil ? 54 : 96 }
    private let hourHeight: CGFloat = 56

    var body: some View {
        GeometryReader { outer in
            let pageWidth = max(outer.size.width - gutterWidth, 1)
            let colWidth = pageWidth / CGFloat(max(days.count, 1))
            let extDays = appState.visibleDays(pageOffset: -1) + days + appState.visibleDays(pageOffset: 1)
            let bars = SpanLayout.bars(days: extDays, store: store, calendar: appState.calendar)
            let laneCount = (bars.map(\.lane).max() ?? -1) + 1

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: gutterWidth, height: 1)
                    paged(pageWidth) {
                        HStack(spacing: 0) {
                            ForEach(extDays, id: \.self) { day in
                                dayHeader(day)
                                    .frame(width: colWidth)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: gutterWidth)
                    paged(pageWidth) {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            ForEach(bars) { bar in
                                SpanBarView(event: bar.event)
                                    .frame(
                                        width: CGFloat(bar.endIndex - bar.startIndex + 1) * colWidth - 4,
                                        height: 16
                                    )
                                    .offset(x: CGFloat(bar.startIndex) * colWidth + 2, y: CGFloat(bar.lane) * 18)
                            }
                        }
                        .frame(width: pageWidth * 3, alignment: .topLeading)
                    }
                }
                .frame(height: max(CGFloat(laneCount) * 18 + 2, 10))
                .padding(.bottom, 3)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        HStack(alignment: .top, spacing: 0) {
                            timeGutter
                            paged(pageWidth) {
                                ZStack(alignment: .topLeading) {
                                    hourLines
                                    HStack(spacing: 0) {
                                        ForEach(extDays, id: \.self) { day in
                                            DayColumn(day: day, colWidth: colWidth, hourHeight: hourHeight)
                                        }
                                    }
                                }
                                .frame(width: pageWidth * 3)
                            }
                        }
                        .frame(height: hourHeight * 24)
                        .padding(.bottom, 20)
                    }
                    .onAppear {
                        proxy.scrollTo("hour-8", anchor: .top)
                    }
                }
            }
            .onAppear {
                appState.weekPageWidth = pageWidth
                appState.gridColumnWidth = colWidth
            }
            .onChange(of: outer.size.width) {
                appState.weekPageWidth = pageWidth
                appState.gridColumnWidth = colWidth
            }
            .onChange(of: days.count) {
                appState.gridColumnWidth = pageWidth / CGFloat(max(days.count, 1))
            }
            .onChange(of: appState.currentDate) {
                guard !appState.isPanning else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { appState.weekPan = 0 }
            }
        }
    }

    /// Clip a 3-page-wide strip to one page and apply the live pan offset.
    private func paged<Content: View>(_ pageWidth: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .offset(x: -pageWidth + appState.weekPan)
            .frame(width: pageWidth, alignment: .leading)
            .clipped()
    }

    private func dayHeader(_ day: Date) -> some View {
        let isToday = day.isSameDay(as: Date(), calendar: appState.calendar)
        return VStack(spacing: 2) {
            Text(Fmt.weekdayShort.string(from: day).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isToday ? Color.red : Color.secondary)
            Text(Fmt.dayNum.string(from: day))
                .font(.system(size: 15, weight: isToday ? .bold : .regular))
                .frame(width: 26, height: 26)
                .background { if isToday { Circle().fill(Color.red) } }
                .foregroundStyle(isToday ? Color.white : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.currentDate = day
            appState.viewMode = .day
        }
    }

    private var timeGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: 0) {
                    if let tz = settings.secondaryTimeZone {
                        Group {
                            if hour > 0 {
                                Text(hourLabel(hour, timeZone: tz))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .offset(y: -6)
                            }
                        }
                        .frame(width: 42, alignment: .topTrailing)
                    }
                    Group {
                        if hour > 0 {
                            Text(hourLabel(hour, timeZone: nil))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 8)
                                .offset(y: -6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
                .frame(width: gutterWidth, height: hourHeight, alignment: .top)
                .id("hour-\(hour)")
            }
        }
        .frame(width: gutterWidth)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Color.clear
                    .frame(height: hourHeight)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    }
            }
        }
    }

    private func hourLabel(_ hour: Int, timeZone: TimeZone?) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        if let timeZone {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("j")
            f.timeZone = timeZone
            return f.string(from: date)
        }
        return Fmt.hour.string(from: date)
    }
}

struct DayColumn: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    let day: Date
    let colWidth: CGFloat
    let hourHeight: CGFloat

    @State private var draftStart: CGFloat?
    @State private var draftEnd: CGFloat?

    var body: some View {
        let timed = store.events(on: day, calendar: appState.calendar).timed
        let positioned = EventLayout.layout(timed)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(createDrag)
                .gesture(SpatialTapGesture().onEnded { value in
                    if appState.availabilityMode {
                        addSlot(fromY: snap(value.location.y), toY: snap(value.location.y) + hourHeight / 2)
                    } else if appState.panelContext != nil {
                        appState.closePanel()
                    } else {
                        createEvent(fromY: snap(value.location.y), toY: snap(value.location.y) + hourHeight)
                    }
                })

            if let s = draftStart, let e = draftEnd {
                RoundedRectangle(cornerRadius: 5)
                    .fill(draftColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(draftColor.opacity(0.6)))
                    .frame(width: colWidth - 6, height: max(abs(e - s), 10))
                    .offset(x: 2, y: min(s, e))
                    .allowsHitTesting(false)
            }

            ForEach(appState.availabilitySlots.filter { $0.start.isSameDay(as: day, calendar: appState.calendar) }) { slot in
                let dayStart = appState.calendar.startOfDay(for: day)
                let y = CGFloat(slot.start.timeIntervalSince(dayStart) / 3600) * hourHeight
                let h = CGFloat(slot.end.timeIntervalSince(slot.start) / 3600) * hourHeight
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.green.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.green.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .frame(width: colWidth - 6, height: max(h, 8))
                    .offset(x: 2, y: y)
                    .onTapGesture {
                        appState.availabilitySlots.removeAll { $0.id == slot.id }
                    }
            }

            ForEach(positioned) { item in
                EventBlockView(item: item, day: day, colWidth: colWidth, hourHeight: hourHeight)
            }

            if day.isSameDay(as: Date(), calendar: appState.calendar) {
                NowLine(hourHeight: hourHeight)
            }
        }
        .frame(width: colWidth, height: hourHeight * 24)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
    }

    private var draftColor: Color {
        appState.availabilityMode ? .green : .accentColor
    }

    private var createDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if draftStart == nil { draftStart = snap(value.startLocation.y) }
                draftEnd = snap(value.location.y)
            }
            .onEnded { _ in
                if let s = draftStart, let e = draftEnd, abs(e - s) >= hourHeight / 8 {
                    if appState.availabilityMode {
                        addSlot(fromY: min(s, e), toY: max(s, e))
                    } else {
                        createEvent(fromY: min(s, e), toY: max(s, e))
                    }
                }
                draftStart = nil
                draftEnd = nil
            }
    }

    private func snap(_ y: CGFloat) -> CGFloat {
        let quarter = hourHeight / 4
        return (y / quarter).rounded() * quarter
    }

    private func date(atY y: CGFloat) -> Date {
        let clamped = max(0, min(y, hourHeight * 24))
        let hours = Double(clamped / hourHeight)
        return appState.calendar.startOfDay(for: day).addingTimeInterval(hours * 3600)
    }

    private func createEvent(fromY: CGFloat, toY: CGFloat) {
        let start = date(atY: fromY)
        var end = date(atY: toY)
        if end <= start { end = start.addingTimeInterval(1800) }
        appState.newEvent(store: store, start: start, end: end)
    }

    private func addSlot(fromY: CGFloat, toY: CGFloat) {
        let start = date(atY: fromY)
        var end = date(atY: toY)
        if end <= start { end = start.addingTimeInterval(1800) }
        appState.availabilitySlots.append(AvailabilitySlot(start: start, end: end))
    }
}

struct NowLine: View {
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let start = Calendar.autoupdatingCurrent.startOfDay(for: context.date)
            let y = CGFloat(context.date.timeIntervalSince(start) / 3600) * hourHeight
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Rectangle().fill(Color.red).frame(height: 1.5)
            }
            .offset(y: y - 3.5)
        }
        .allowsHitTesting(false)
    }
}

struct EventBlockView: View {
    @EnvironmentObject var store: CalendarStore
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    let item: PositionedEvent
    let day: Date
    let colWidth: CGFloat
    let hourHeight: CGFloat

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var resizeDelta: CGFloat = 0
    @State private var resizingTop = false
    @State private var isResizing = false

    private var isEditable: Bool {
        item.event.calendar?.allowsContentModifications == true
    }

    var body: some View {
        let cal = appState.calendar
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let start = max(item.event.startDate ?? dayStart, dayStart)
        let end = min(item.event.endDate ?? dayEnd, dayEnd)
        var y = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
        var height = max(CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight, 16)
        let subWidth = (colWidth - 6) / CGFloat(item.columnCount)
        let x = 2 + subWidth * CGFloat(item.column)
        let color = item.event.calendar?.displayColor ?? Color.accentColor
        let isSelected = appState.selectedKey == item.id
        let isPast = (item.event.endDate ?? Date()) < Date()
        let joinURL = MeetLink.url(for: item.event)

        if isResizing {
            if resizingTop {
                y += resizeDelta
                height = max(height - resizeDelta, hourHeight / 4)
            } else {
                height = max(height + resizeDelta, hourHeight / 4)
            }
        }

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(item.event.title ?? "Untitled")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(height > 32 ? 2 : 1)
                if joinURL != nil, height > 20, subWidth > 60 {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8))
                }
            }
            if height > 34, let s = item.event.startDate, let e = item.event.endDate {
                Text(Fmt.interval.string(from: s, to: e))
                    .font(.system(size: 9))
                    .opacity(0.75)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .frame(width: max(subWidth - 2, 12), height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(
            item.event.needsMyResponse ? 0.07 : isSelected ? 0.28 : 0.16
        )))
        .overlay(alignment: .leading) {
            if !item.event.needsMyResponse {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            if item.event.needsMyResponse {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: isSelected ? 1.8 : 1.2, dash: [4, 3]))
            } else if isSelected {
                RoundedRectangle(cornerRadius: 5).strokeBorder(color, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .top) {
            if isEditable, !appState.availabilityMode {
                resizeHandle(top: true)
            }
        }
        .overlay(alignment: .bottom) {
            if isEditable, !appState.availabilityMode {
                resizeHandle(top: false)
            }
        }
        .opacity((isDragging ? 0.7 : 1) * (isPast && !isSelected ? 0.55 : 1))
        .offset(x: x + dragOffset.width, y: y + dragOffset.height)
        .onTapGesture { appState.select(item.event) }
        .gesture(moveDrag)
        .contextMenu { contextMenuItems(joinURL: joinURL) }
    }

    @ViewBuilder
    private func contextMenuItems(joinURL: URL?) -> some View {
        if item.event.attendees?.isEmpty == false {
            Menu("RSVP") {
                Button("Going") { rsvp("accepted") }
                Button("Maybe") { rsvp("tentative") }
                Button("Not going") { rsvp("declined") }
            }
        }
        if let joinURL {
            Button {
                openURL(joinURL)
            } label: {
                Label("Join meeting", systemImage: "video")
            }
        }
        Button {
            appState.select(item.event)
        } label: {
            Label("Open", systemImage: "sidebar.right")
        }
        if isEditable {
            Button {
                store.duplicate(item.event)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Menu("Move to calendar") {
                ForEach(store.writableCalendars, id: \.calendarIdentifier) { cal in
                    Button(cal.title) { store.move(item.event, to: cal) }
                }
            }
        }
        Button {
            Clipboard.copy(item.event.title ?? "")
        } label: {
            Label("Copy title", systemImage: "doc.on.doc")
        }
        if isEditable {
            Divider()
            Button(role: .destructive) {
                appState.requestDelete(item.event, store: store)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func rsvp(_ status: String) {
        let event = item.event
        let state = appState
        Task { await GoogleSync.respond(event: event, status: status, appState: state) }
    }

    private func resizeHandle(top: Bool) -> some View {
        Color.clear
            .frame(height: 7)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isResizing = true
                        resizingTop = top
                        resizeDelta = value.translation.height
                    }
                    .onEnded { value in
                        defer {
                            isResizing = false
                            resizeDelta = 0
                        }
                        let minutes = (Double(value.translation.height / hourHeight) * 60 / 15).rounded() * 15
                        guard minutes != 0 else { return }
                        let snapshot = EventSnapshot(item.event)
                        if top {
                            let newStart = item.event.startDate.addingTimeInterval(minutes * 60)
                            guard newStart < item.event.endDate else { return }
                            item.event.startDate = newStart
                        } else {
                            let newEnd = item.event.endDate.addingTimeInterval(minutes * 60)
                            guard newEnd > item.event.startDate else { return }
                            item.event.endDate = newEnd
                        }
                        appState.commitChange(to: item.event, snapshot: snapshot, isNew: false, store: store)
                    }
            )
    }

    private var moveDrag: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard isEditable else { return }
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                defer {
                    isDragging = false
                    dragOffset = .zero
                }
                guard isEditable else { return }
                let minuteDelta = (Double(value.translation.height / hourHeight) * 60 / 15).rounded() * 15
                let dayDelta = (value.translation.width / colWidth).rounded()
                guard minuteDelta != 0 || dayDelta != 0 else { return }
                let interval = minuteDelta * 60 + Double(dayDelta) * 86400
                var isOption = false
                #if os(macOS)
                isOption = NSEvent.modifierFlags.contains(.option)
                #endif
                if isOption {
                    store.duplicate(item.event, dayOffset: interval / 86400)
                } else {
                    let snapshot = EventSnapshot(item.event)
                    item.event.startDate = item.event.startDate.addingTimeInterval(interval)
                    item.event.endDate = item.event.endDate.addingTimeInterval(interval)
                    appState.commitChange(to: item.event, snapshot: snapshot, isNew: false, store: store)
                }
            }
    }
}
