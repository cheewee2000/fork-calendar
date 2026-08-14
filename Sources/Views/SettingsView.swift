#if os(macOS)
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var googleAuth = GoogleAuth.shared

    private static let timeZones = AppSettings.curatedTimeZones

    /// Selecting from the picker appends to the list, then the picker resets.
    private var addTimeZoneBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { id in
                guard !id.isEmpty, !settings.secondaryTZs.contains(id) else { return }
                settings.secondaryTZs.append(id)
            }
        )
    }

    var body: some View {
        Form {
            Picker("Start week on", selection: $settings.firstWeekday) {
                Text("System default").tag(0)
                Text("Sunday").tag(1)
                Text("Monday").tag(2)
            }
            Picker("Default event duration", selection: $settings.defaultDuration) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            Toggle("Show weekends in week view", isOn: $settings.showWeekends)
            Toggle("Show declined events", isOn: $settings.showDeclined)
            Toggle("Month view: all-day events only", isOn: $settings.monthAllDayOnly)
            TextField("Zoom personal meeting URL", text: $settings.zoomLink, prompt: Text("https://zoom.us/j/…"))
            ForEach(settings.secondaryTZs, id: \.self) { id in
                HStack {
                    Text("Time zone: \(AppSettings.timeZoneLabel(id))")
                    Spacer()
                    Button {
                        settings.secondaryTZs.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Add time zone", selection: addTimeZoneBinding) {
                Text("Choose…").tag("")
                ForEach(Self.timeZones.filter { !settings.secondaryTZs.contains($0) }, id: \.self) { id in
                    Text(id.replacingOccurrences(of: "_", with: " ")).tag(id)
                }
            }
            Section("Google account (guest lists & Meet links)") {
                TextField("OAuth Client ID", text: $settings.googleClientID)
                TextField("OAuth Client Secret", text: $settings.googleClientSecret)
                HStack {
                    if googleAuth.isConnected {
                        Button("Disconnect") {
                            googleAuth.disconnect()
                            GoogleSync.clearCache()
                        }
                    } else {
                        Button("Connect Google…") {
                            Task { await googleAuth.connect() }
                        }
                        .disabled(settings.googleClientID.isEmpty)
                    }
                    Text(googleAuth.isConnected ? "Connected" : googleAuth.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Create a **Desktop app** OAuth client at console.cloud.google.com (APIs & Services → Credentials) with the Google Calendar API enabled, then paste its ID and secret here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
#endif
