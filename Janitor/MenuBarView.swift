import SwiftUI

struct MenuBarView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Janitor").font(.headline)
                Spacer()
                Text("CPU \(Int(monitor.totalCPU.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            NoticeBanner()

            if monitor.sims.isEmpty {
                Label("No simulators running", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Simulators").font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    ForEach(monitor.sims) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).lineLimit(1)
                                Text("\(Format.cpu(device.cpu)) · \(Format.memory(device.memory)) · \(device.usageText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            if monitor.shuttingDown.contains(device.udid) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Shut Down") { monitor.shutDown(device) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    Button {
                        Task { await monitor.shutDownAllSimulators() }
                    } label: {
                        Text("Shut Down All Simulators").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Top CPU").font(.subheadline.weight(.semibold))
                ForEach(monitor.rows.sorted { $0.cpu > $1.cpu }.prefix(5)) { row in
                    HStack {
                        Text(row.name).lineLimit(1)
                        if monitor.isHog(row) {
                            Image(systemName: "flame.fill").foregroundStyle(.orange).font(.caption)
                        }
                        Spacer()
                        Text(Format.cpu(row.cpu)).monospacedDigit().foregroundStyle(.secondary)
                        Button {
                            monitor.quit(row)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Quit \(row.name)")
                    }
                }
            }

            if let last = monitor.events.first {
                Divider()
                Text("\(last.text) · \(last.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            @Bindable var monitor = monitor
            Toggle("Auto-clean idle simulators (\(monitor.idleMinutes) min)", isOn: $monitor.autoShutdown)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Text("Free disk \(Format.disk(monitor.freeDiskBytes))")
                    .foregroundStyle(monitor.freeDiskBytes < CleanupPolicy.lowDiskBytes ? .orange : .secondary)
                Spacer()
                Button("Disk Cleanup…") {
                    openWindow(id: "cleanup")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }
            .font(.callout)

            HStack {
                Button("Open Janitor") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
