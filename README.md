# Fork Calendar

A native Notion-Calendar-style calendar app for macOS and iOS, built with SwiftUI + EventKit. Reads and edits your real system calendars (iCloud, Google via macOS/iOS accounts, etc.).

**v0.1.0**

## Features

- Day / Week / Month views (⌘1/⌘2/⌘3), ⌘T today, ⌘←/⌘→ navigate
- Sidebar with mini-month and per-calendar show/hide toggles, grouped by account
- Week/day time grid with red now-line, overlapping-event layout, all-day row
- Click-drag on empty grid to create an event; drag an event block to move it (15-min snap, across days)
- Event editor: title, calendar, all-day, times, location, notes, delete
- ⌘N new event

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
