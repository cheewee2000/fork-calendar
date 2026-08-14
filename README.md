# Fork Calendar

A native Notion-Calendar-style calendar app for macOS and iOS, built with SwiftUI + EventKit. Reads and edits your real system calendars (iCloud, Google via macOS/iOS accounts, etc.).

**v0.2.0**

## Features

- Day / N-day (1–9) / Week / Month views
- Right-hand event panel (Notion-style): click an event to open, edit inline
- Sidebar with mini-month and per-calendar show/hide toggles, grouped by account
- Time grid: red now-line, overlapping-event layout, all-day row, past events dimmed
- Drag on empty grid to create; drag events to move (15-min snap, across days); drag top/bottom edges to resize; ⌥-drag to duplicate
- Right-click context menus: join meeting, duplicate, move to calendar, copy title, delete
- ⌘K command menu: commands, event search (±1 year), "go to date" (e.g. `friday`, `9/22`, `tomorrow`)
- Share availability: press S, drag slots, copy as text
- Recurring events (daily/weekdays/weekly/biweekly/monthly/yearly) with "this event / all future" prompts
- Attendees with RSVP status; join-meeting detection (Zoom, Meet, Teams, Webex, …)
- Undo (⌘Z) for moves, edits, deletes, and creates
- macOS menu bar agenda with next event + Join buttons
- Settings (⌘,): week start, default duration, weekends, declined events, secondary time zone in the gutter

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| T | Today |
| D / W / M | Day / Week / Month view |
| 1–9 | Show N days |
| ← / → | Previous / next period |
| C | Create event |
| S | Share availability |
| ⌘K | Search & commands |
| ⌘Z | Undo |
| ⌘N | New event |
| ⌘\ | Toggle sidebar |
| Esc | Close panel / palette / availability |
| ⌫ | Delete selected event |

## Building

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
# macOS
xcodebuild -project ForkCalendar.xcodeproj -scheme ForkCalendar build
# iOS simulator
xcodebuild -project ForkCalendar.xcodeproj -scheme ForkCalendar-iOS -destination 'generic/platform=iOS Simulator' build
```

Targets: macOS 14+, iOS 17+. Grant calendar access on first launch.
