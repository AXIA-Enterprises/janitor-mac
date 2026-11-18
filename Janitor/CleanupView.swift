import SwiftUI

/// State behind the Disk Cleanup window.
@MainActor
@Observable
final class CleanupModel {
    private(set) var plan: CleanupPlan?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var resultText: String?
    private(set) var resultFailed = false
    private(set) var agentInstalled = false
    private(set) var idleSimulators: [(device: SimDevice, dataBytes: Int64)] = []
    private(set) var isErasing = false

    var idleSimulatorBytes: Int64 { idleSimulators.reduce(0) { $0 + $1.dataBytes } }

    /// Dry run: works out what would be deleted and how big it is. Deletes nothing.
    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        Task {
            async let newPlan = Task.detached(priority: .userInitiated) {
                Cleaner.plan(config: .live, estimateSizes: true)
            }.value
            async let installed = Task.detached { LaunchAgent.isInstalled }.value
            async let simulators = SimulatorService.shutdownDevices()
            plan = await newPlan
            agentInstalled = await installed
            idleSimulators = await simulators
            isScanning = false
        }
    }

    func cleanNow() {
        guard !isCleaning, !isScanning, plan?.deletions.isEmpty == false else { return }
        isCleaning = true
        resultText = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Cleaner.clean(config: .live, trigger: "Clean Now button")
            }.value
            if let blocked = result.blocked {
                resultText = "Nothing deleted: \(blocked)."
                resultFailed = true
            } else {
                let skipped = result.skipped.isEmpty ? "" : " \(result.skipped.count) skipped because they came into use."
                resultText = "Deleted \(result.deleted.count) folder\(result.deleted.count == 1 ? "" : "s"). Free disk went from \(Format.disk(result.freeBefore)) to \(Format.disk(result.freeAfter)).\(skipped)"
                resultFailed = false
            }
            isCleaning = false
            scan()
        }
    }

    func setSchedule(_ enabled: Bool) {
        Task {
            let error = await Task.detached { () -> String? in
                if enabled { return LaunchAgent.install() }
                LaunchAgent.uninstall()
                return nil
            }.value
            if let error {
                resultText = error
                resultFailed = true
            }
            agentInstalled = await Task.detached { LaunchAgent.isInstalled }.value
        }
    }

    func eraseIdleSimulators() {
        guard !isErasing, !idleSimulators.isEmpty else { return }
        isErasing = true
        let targets = idleSimulators
        Task {
            let log = CleanupLog(config: .live)
            let before = SystemStats.freeDiskBytes(at: NSHomeDirectory()) ?? 0
            var erased = 0
            for (device, _) in targets {
                if await SimulatorService.erase(device.udid) {
                    erased += 1
                    log.write("ERASED simulator \(device.name) (\(device.udid))")
                } else {
                    log.write("SKIP simulator \(device.name) (\(device.udid)): erase failed")
                }
            }
            let after = SystemStats.freeDiskBytes(at: NSHomeDirectory()) ?? before
            resultText = "Erased \(erased) of \(targets.count) shut-down simulators. Free disk went from \(Format.disk(before)) to \(Format.disk(after))."
            resultFailed = erased < targets.count
            idleSimulators = await SimulatorService.shutdownDevices()
            isErasing = false
        }
    }
}

struct CleanupView: View {
    @Environment(Monitor.self) private var monitor
    @State private var model = CleanupModel()
    @State private var confirmErase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SystemPressureBar()

            if let text = model.resultText {
                Label(text, systemImage: model.resultFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.resultFailed ? Color.red : Color.green).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }

            header
            list
            footer

            Divider()

            Toggle(isOn: Binding(get: { model.agentInstalled }, set: { model.setSchedule($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean automatically every 2 hours")
                    Text("Runs in the background even when Janitor is closed. Deletions are logged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shut-down simulators")
                    Text(model.idleSimulators.isEmpty
                         ? "None found"
                         : "\(model.idleSimulators.count) devices holding \(Format.disk(model.idleSimulatorBytes)) of apps and data. Never erased automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isErasing { ProgressView().controlSize(.small) }
                Button("Erase Idle Simulators…", role: .destructive) { confirmErase = true }
                    .disabled(model.idleSimulators.isEmpty || model.isErasing)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .task { model.scan() }
        .confirmationDialog(
            "Erase \(model.idleSimulators.count) shut-down simulators?",
            isPresented: $confirmErase
        ) {
            Button("Erase \(model.idleSimulators.count) Simulators", role: .destructive) { model.eraseIdleSimulators() }
        } message: {
            Text("Every app installed on them and all their data is removed. The devices themselves stay. Booted simulators are not touched. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Old build folders").font(.headline)
            if let plan = model.plan {
                Text(plan.lowDisk
                     ? "Low-disk mode: anything unused for 6 hours"
                     : "Unused for 2 days (session build folders: 1 day)")
                    .font(.callout)
                    .foregroundStyle(plan.lowDisk ? .orange : .secondary)
            }
            Spacer()
            Button("Open Log") { NSWorkspace.shared.open(CleanupConfig.live.logDirectory) }
            Button("Rescan") { model.scan() }.disabled(model.isScanning || model.isCleaning)
        }
    }

    @ViewBuilder private var list: some View {
        if let plan = model.plan {
            if plan.items.isEmpty {
                ContentUnavailableView("No build folders found", systemImage: "folder")
                    .frame(maxHeight: .infinity)
            } else {
                List(plan.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.verdict.willDelete ? "trash" : "lock")
                            .foregroundStyle(item.verdict.willDelete ? .red : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text(detail(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let bytes = item.estimatedBytes {
                            Text(Format.disk(bytes)).monospacedDigit()
                        }
                    }
                    .help(item.url.path)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Checking which folders are unused and measuring them…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if model.isScanning, model.plan != nil { ProgressView().controlSize(.small) }
            if let plan = model.plan {
                if !plan.inUseCheckReliable {
                    Text("Could not list open files, so everything is kept.").foregroundStyle(.orange)
                } else if plan.deletions.isEmpty {
                    Text("Nothing to delete. Preview only, nothing has been removed.").foregroundStyle(.secondary)
                } else {
                    Text("Preview: \(plan.deletions.count) of \(plan.items.count) folders would be deleted, about \(Format.disk(plan.estimatedBytes)). Nothing has been removed yet.")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isCleaning { ProgressView().controlSize(.small) }
            Button("Clean Now") { model.cleanNow() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCleaning || model.isScanning || model.plan?.deletions.isEmpty != false)
        }
        .font(.callout)
    }

    private func detail(for item: CleanupItem) -> String {
        let age = "last used \(Format.duration(Date().timeIntervalSince(item.lastUsed))) ago"
        switch item.verdict {
        case .delete: return "\(item.kind.rawValue) · \(age) · \(item.url.deletingLastPathComponent().path)"
        case .keep(let reason): return "Kept · \(reason)"
        }
    }
}

/// Free disk, swap and running builds: the three numbers that explain a struggling machine.
struct SystemPressureBar: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        HStack(spacing: 12) {
            pressureTile("Free Disk", Format.disk(monitor.freeDiskBytes), color: diskColor,
                         note: monitor.freeDiskBytes < CleanupPolicy.lowDiskBytes ? "Low: cleanup limits tightened" : nil)
            pressureTile("Swap Used", Format.disk(Int64(monitor.swapUsedBytes)), color: swapColor,
                         note: monitor.swapTotalBytes > 0 ? "of \(Format.disk(Int64(monitor.swapTotalBytes)))" : nil)
            pressureTile("xcodebuild Running", "\(monitor.xcodebuildCount)", color: .primary, note: nil)
        }
    }

    private var diskColor: Color {
        if monitor.freeDiskBytes < CleanupPolicy.criticalDiskBytes { return .red }
        return monitor.freeDiskBytes < CleanupPolicy.lowDiskBytes ? .orange : .primary
    }

    private var swapColor: Color {
        guard monitor.swapTotalBytes > 0 else { return .primary }
        return Double(monitor.swapUsedBytes) / Double(monitor.swapTotalBytes) > 0.8 ? .orange : .primary
    }

    private func pressureTile(_ title: String, _ value: String, color: Color, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
