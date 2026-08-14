#if os(macOS)
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

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
            Picker("Secondary time zone", selection: $settings.secondaryTZ) {
                Text("None").tag("")
                ForEach(Self.timeZones, id: \.self) { id in
                    Text(id.replacingOccurrences(of: "_", with: " ")).tag(id)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
#endif
