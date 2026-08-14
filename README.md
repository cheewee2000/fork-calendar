# Fork Calendar

A native Notion-Calendar-style calendar app for macOS and iOS, built with SwiftUI + EventKit. Reads and edits your real system calendars (iCloud, Google via macOS/iOS accounts, etc.).

**v0.5.2**

## Features

- Day / N-day (1–9) / Week / Month / Year views
- Month view scrolls continuously through the year; drag event chips between days
- Year view: whole year as a stack of weeks with event dots (Y)
- Right-hand event panel (Notion-style): click an event to open, edit inline
- Sidebar with mini-month and per-calendar show/hide toggles, grouped by account
- Time grid: red now-line, overlapping-event layout, all-day row, past events dimmed
- Drag on empty grid to create; drag events to move (15-min snap, across days); drag top/bottom edges to resize; ⌥-drag to duplicate
- Right-click context menus: join meeting, duplicate, move to calendar, copy title, delete
- ⌘K command menu: commands, event search (±1 year), "go to date", and natural-language quick add ("Lunch with Amy tomorrow 1pm")
- Share availability: press S, drag slots, copy as text
- Recurring events (daily/weekdays/weekly/biweekly/monthly/yearly) with "this event / all future" prompts
- Attendees with RSVP status; join-meeting detection (Zoom, Meet, Teams, Webex, …)
- Add conferencing: Zoom personal room (set in Settings), Google Meet create-and-paste, or paste any link
- Invite people by email — sends a standards-compliant .ics invite via Mail/share sheet
- Gmail shared calendars via delegate calendar sources
- Multi-day/all-day events render as single continuous bars across days (week + month views)
- Week/day views side-scroll smoothly day-by-day (trackpad); a light snap engages only within a day of full-week framing
- Custom per-calendar colors (hover a sidebar calendar → palette, presets or any color)
- Google account connection (your own OAuth client): real Google-side guest lists with email invites, auto-created Google Meet links, and RSVP (Going/Maybe/No) from the event panel or right-click
- Events awaiting your RSVP show a dotted outline
- Undo (⌘Z) for moves, edits, deletes, and creates
- macOS menu bar agenda with next event + Join buttons
- Settings (⌘,): week start, default duration, weekends, declined events, secondary time zone in the gutter

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| T | Today |
| D / W / M / Y | Day / Week / Month / Year view |
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
