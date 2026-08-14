#if os(macOS)
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var googleAuth = GoogleAuth.shared

    private static let timeZones: [String] = [
        "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
        "America/Sao_Paulo", "Europe/London", "Europe/Paris", "Europe/Berlin",
        "Europe/Madrid", "Africa/Cairo", "Asia/Dubai", "Asia/Kolkata",
        "Asia/Shanghai", "Asia/Tokyo", "Asia/Seoul", "Asia/Singapore",
        "Australia/Sydney", "Pacific/Auckland", "UTC",
    ]

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
            TextField("Zoom personal meeting URL", text: $settings.zoomLink, prompt: Text("https://zoom.us/j/…"))
            Picker("Secondary time zone", selection: $settings.secondaryTZ) {
                Text("None").tag("")
                ForEach(Self.timeZones, id: \.self) { id in
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
