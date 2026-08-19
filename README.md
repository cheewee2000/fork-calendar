# Fork Calendar

A native Notion-Calendar-style calendar app for macOS and iOS, built with SwiftUI on the Google Calendar API. Sign in to each Google account directly — no dependency on the system Calendar app, its accounts, or its sync.

**v0.14.0**

## Google accounts & sync

- Settings (⌘, / gear in the sidebar) → **Add Google account…** opens Google's sign-in page; add as many accounts as you like, each with its own calendars and its own token. Toggle sync per account, remove accounts any time.
- You supply the OAuth client (console.cloud.google.com → APIs & Services → Credentials, with the Calendar API enabled). macOS uses a **Desktop app** client (loopback redirect); iOS uses an **iOS** client for bundle ID `com.cwandt.forkcalendar.app` (falls back to the desktop client).
- Everything is cached locally (JSON in Application Support / the app group) and kept fresh with Google's incremental sync tokens. Launch shows the cache instantly, then syncs.
- **Sync control:** pick the background interval (manual / 1 / 2 / 5 / 15 min), whether to sync when the app becomes active, ⌘R (or R) for a full pass right now, and "clear cache and re-download" if something looks off. Edits go to Google immediately.
- **RSVP & notification control:** choose whether RSVPs email the organizer, and whether changes to events with guests (create, move, edit, delete, invite) email the guests — always, never, or ask each time. Guests and Google Meet links are part of the same save.
- Recurring events: "this event" patches the instance; "this and all future" patches the series when it's the first occurrence, otherwise ends the old series and starts a new one.
- iOS widget reads the app's published snapshot (today + 2 days).

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
- Invite people by email — added to the Google guest list on save (email per your notification setting)
- Multi-day/all-day events render as single continuous bars across days (week + month views)
- Week/day views side-scroll smoothly day-by-day (trackpad); a light snap engages only within a day of full-week framing
- Custom per-calendar colors (hover a sidebar calendar → palette, presets or any color)
- Guest lists, auto-created Google Meet links, and RSVP (Going/Maybe/No) from the event panel or right-click — per account, so invites to any signed-in account can be answered
- Events awaiting your RSVP show a dotted outline
- Undo (⌘Z) for moves, edits, deletes, and creates
- macOS menu bar agenda with next event + Join buttons
- Settings (⌘,): accounts, sync cadence, guest/RSVP emails, default calendar, week start, default duration, weekends, declined events, secondary time zones in the gutter

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

Targets: macOS 15+, iOS 18+. Add a Google account on first launch.
