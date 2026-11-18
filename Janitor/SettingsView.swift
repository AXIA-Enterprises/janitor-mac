import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var monitor = monitor
        Form {
            Section("Simulators") {
                Toggle("Automatically shut down idle simulators", isOn: $monitor.autoShutdown)
                Stepper("After \(monitor.idleMinutes) minutes unused",
                        value: $monitor.idleMinutes, in: 1...240, step: 5)
                    .disabled(!monitor.autoShutdown)
                Text("A simulator is idle when no installed app on it is doing any work, no tests are running on it, no xcodebuild is targeting it, and the Simulator app is not in front. Each device has its own timer. Janitor must be running for this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("CPU Hogs") {
                Slider(value: $monitor.hogThreshold, in: 20...200, step: 10) {
                    Text("Flag above \(Int(monitor.hogThreshold))% CPU")
                }
                Text("Background processes above this for \(Int(Monitor.hogSustainSeconds)) seconds are flagged. 100% is one full core. Janitor never quits these on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Janitor at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            if !monitor.events.isEmpty {
                Section("Recent Activity") {
                    ForEach(monitor.events.prefix(8)) { event in
                        HStack {
                            Text(event.text)
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
