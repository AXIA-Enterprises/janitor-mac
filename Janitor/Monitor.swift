import AppKit
import Observation

struct JanitorEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

@MainActor
@Observable
final class Monitor {
    // Live state
    private(set) var rows: [ProcRow] = []
    private(set) var sims: [SimDevice] = []
    private(set) var totalCPU: Double = 0
    private(set) var cpuHistory: [Double] = []
    private(set) var events: [JanitorEvent] = []
    private(set) var shuttingDown: Set<String> = []
    /// The most recent action that did not take effect, shown until dismissed.
    private(set) var notice: String?
    /// Same numbers as `df`, `sysctl vm.swapusage` and a count of xcodebuild processes,
    /// so the cause of a slow or full machine is visible at a glance.
    private(set) var freeDiskBytes: Int64 = 0
    private(set) var swapUsedBytes: UInt64 = 0
    private(set) var swapTotalBytes: UInt64 = 0
    private(set) var xcodebuildCount = 0

    // Settings (persisted)
    var autoShutdown: Bool { didSet { defaults.set(autoShutdown, forKey: "autoShutdown") } }
    var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: "idleMinutes") } }
    var hogThreshold: Double { didSet { defaults.set(hogThreshold, forKey: "hogThreshold") } }

    /// A process counts as a hog after this long above the threshold while not in front.
    static let hogSustainSeconds = 20.0
    static let refreshSeconds = 2.0
    static let backgroundRefreshSeconds = 5.0

    private let defaults = UserDefaults.standard
    private let sampler = ProcessSampler()
    private var deviceInfo: [String: SimDevice] = [:]
    private var lastDeviceRefresh = Date.distantPast
    private var simIdleSince: [String: Date] = [:]
    private var loop: Task<Void, Never>?
    private var testLogPath: String?
    private var appCache: [pid_t: (name: String, isRegular: Bool)] = [:]
    /// Without this, App Nap suspends our timer whenever no Janitor window is visible,
    /// which is exactly when the background watching matters.
    private let napGuard = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Monitoring CPU usage in the background")

    init() {
        let store = UserDefaults.standard
        store.register(defaults: ["autoShutdown": true, "idleMinutes": 30, "hogThreshold": 50.0])
        autoShutdown = store.bool(forKey: "autoShutdown")
        idleMinutes = store.integer(forKey: "idleMinutes")
        hogThreshold = store.double(forKey: "hogThreshold")
        if store.bool(forKey: "JanitorTestHooks") { installTestHooks() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Sample less often when nobody is looking at a Janitor window.
                let watching = NSApp?.windows.contains {
                    $0.isVisible && $0.occlusionState.contains(.visible) && !$0.className.contains("StatusBar")
                } ?? false
                try? await Task.sleep(for: .seconds(watching ? Self.refreshSeconds : Self.backgroundRefreshSeconds))
            }
        }
    }

    // MARK: Derived

    var hogs: [ProcRow] { rows.filter(isHog).sorted { $0.cpu > $1.cpu } }
    var simCPU: Double { sims.reduce(0) { $0 + $1.cpu } }
    var simMemory: UInt64 { sims.reduce(0) { $0 + $1.memory } }

    func isHog(_ row: ProcRow) -> Bool {
        row.hogSeconds >= Self.hogSustainSeconds && !row.isFrontmost && row.pid != getpid()
    }

    // MARK: Sampling

    private func tick() async {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Asking LaunchServices for names is the expensive part of a tick, so remember them per pid.
        var apps: [pid_t: AppInfo] = [:]
        var stillRunning: [pid_t: (name: String, isRegular: Bool)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            let known = appCache[pid] ?? (app.localizedName ?? "", app.activationPolicy == .regular)
            stillRunning[pid] = known
            if !known.name.isEmpty {
                apps[pid] = AppInfo(name: known.name, isRegular: known.isRegular, isFrontmost: pid == frontPID)
            }
        }
        appCache = stillRunning

        let snapshot = await sampler.sample(apps: apps, hogThreshold: hogThreshold)
        var newRows = snapshot.rows
        totalCPU = snapshot.totalCPU
        cpuHistory.append(snapshot.totalCPU)
        if cpuHistory.count > 90 { cpuHistory.removeFirst(cpuHistory.count - 90) }

        // Only shell out to simctl when the set of booted devices changes (or occasionally).
        let udids = Set(snapshot.simRoots.values)
        if udids != Set(deviceInfo.keys) || Date().timeIntervalSince(lastDeviceRefresh) > 60 {
            if !udids.isEmpty || !deviceInfo.isEmpty {
                lastDeviceRefresh = Date()
                let devices = await SimulatorService.bootedDevices()
                deviceInfo = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0) })
            }
        }

        // Each device's GPU work happens in host-side SimMetalHost processes that live outside
        // the device's process tree; they are labelled "SimMetalHost (<device name>: ...)".
        for index in newRows.indices where newRows[index].simUDID == nil && newRows[index].name.hasPrefix("SimMetalHost (") {
            let label = newRows[index].name.dropFirst("SimMetalHost (".count)
            if let device = deviceInfo.values.first(where: { label.hasPrefix($0.name + ":") }) {
                newRows[index].simUDID = device.udid
                newRows[index].kind = .simulator
            }
        }
        rows = newRows

        var built: [SimDevice] = []
        let now = Date()
        let simulatorInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SimulatorService.simulatorBundleID
        for udid in udids {
            var device = deviceInfo[udid] ?? SimDevice(udid: udid, name: "Simulator", runtime: "")
            var appActive = false, testing = false
            for row in newRows where row.simUDID == udid {
                device.cpu += row.cpu
                device.memory += row.memory
                device.processCount += 1
                // A suspended background app uses no CPU at all, so any activity means an app is live.
                if row.isUserSimApp && row.cpu > 0.05 { appActive = true }
                if row.name == "xctest" || row.name.hasSuffix("-Runner") { testing = true }
            }
            let named = deviceInfo[udid] != nil
            if simulatorInFront {
                device.inUseReason = "Simulator app is in front"
            } else if appActive {
                device.inUseReason = "an app is active"
            } else if testing {
                device.inUseReason = "tests are running"
            } else if snapshot.buildCommands.contains(where: {
                $0.localizedCaseInsensitiveContains(udid) || (named && $0.contains("name=\(device.name)"))
            }) {
                device.inUseReason = "xcodebuild is targeting it"
            }
            // The idle clock starts when a device is first seen and restarts whenever it is used.
            if device.inUseReason != nil || simIdleSince[udid] == nil { simIdleSince[udid] = now }
            device.idleSince = simIdleSince[udid]
            built.append(device)
        }
        simIdleSince = simIdleSince.filter { udids.contains($0.key) }
        // Keep cards in a fixed order so a Shut Down button never moves under the cursor.
        sims = built.sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
        shuttingDown.formIntersection(udids)

        if autoShutdown {
            let limit = Double(max(idleMinutes, 1)) * 60
            for device in sims where device.inUseReason == nil && !shuttingDown.contains(device.udid) {
                if let since = device.idleSince, now.timeIntervalSince(since) >= limit {
                    shutDown(device, auto: true)
                }
            }
        }

        // Disk, swap and build pressure.
        freeDiskBytes = SystemStats.freeDiskBytes(at: NSHomeDirectory()) ?? 0
        if let swap = SystemStats.swapUsage() {
            swapUsedBytes = swap.used
            swapTotalBytes = swap.total
        }
        xcodebuildCount = newRows.filter { $0.name == "xcodebuild" }.count
        if freeDiskBytes > 0, freeDiskBytes < CleanupPolicy.criticalDiskBytes {
            LowDiskNotifier.post(freeBytes: freeDiskBytes)
        }
    }

    // MARK: Actions

    func shutDown(_ device: SimDevice, auto: Bool = false) {
        guard !shuttingDown.contains(device.udid) else { return }
        shuttingDown.insert(device.udid)
        Task {
            let accepted = await SimulatorService.shutdown(device.udid)
            // Don't trust the exit code alone: ask again which devices are still booted.
            let stillBooted = await SimulatorService.bootedDevices().contains { $0.udid == device.udid }
            lastDeviceRefresh = .distantPast
            if accepted && !stillBooted {
                log(auto ? "Auto shut down \(device.name) after \(idleMinutes) min idle, confirmed off"
                         : "Shut down \(device.name), confirmed off")
            } else {
                shuttingDown.remove(device.udid)
                fail("Could not shut down \(device.name). It is still booted.")
            }
        }
    }

    func shutDownAllSimulators(auto: Bool = false) async {
        guard !sims.isEmpty else { return }
        let count = sims.count
        shuttingDown.formUnion(sims.map(\.udid))
        await SimulatorService.shutdownAll()
        let remaining = await SimulatorService.bootedDevices()
        lastDeviceRefresh = .distantPast
        guard remaining.isEmpty else {
            shuttingDown.removeAll()
            fail("\(remaining.count) of \(count) simulators are still booted after Shut Down All.")
            return
        }
        // With nothing booted the Simulator app is just an empty shell; close it too.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: SimulatorService.simulatorBundleID) {
            app.terminate()
        }
        let plural = count == 1 ? "" : "s"
        log(auto ? "Auto-cleaned \(count) idle simulator\(plural) after \(idleMinutes) min unused, confirmed off"
                 : "Shut down all \(count) simulator\(plural), confirmed off")
    }

    func quit(_ row: ProcRow, force: Bool = false) {
        let verb = force ? "Force quit" : "Quit"
        let sent: Bool
        if row.kind == .app, let app = NSRunningApplication(processIdentifier: row.pid) {
            sent = force ? app.forceTerminate() : app.terminate()
        } else {
            sent = kill(row.pid, force ? SIGKILL : SIGTERM) == 0
        }
        guard sent else {
            fail("\(verb) failed for \(row.name): macOS refused the request.")
            return
        }
        Task {
            // Report success only once the process has really exited.
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                if !Self.isRunning(row.pid) {
                    log("\(verb) \(row.name), confirmed gone")
                    return
                }
            }
            fail(force ? "\(row.name) is still running after Force Quit."
                       : "\(row.name) is still running after Quit (it may be asking to save). Right-click it and choose Force Quit.")
        }
    }

    func dismissNotice() { notice = nil }

    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != 5 // SZOMB: exited, just not reaped by its parent yet
    }

    private func fail(_ text: String) {
        notice = text
        log("Failed: " + text)
    }

    func quitAllHogs() {
        for row in hogs where row.simUDID == nil { quit(row) }
    }

    // MARK: Test hooks

    /// Only active when launched with `-JanitorTestHooks YES`. Lets a script drive the same
    /// methods the buttons call ("shutdown:<udid>", "quit:<pid>", "forcequit:<pid>") and
    /// mirrors the activity log to a file so results can be checked from outside.
    private func installTestHooks() {
        testLogPath = UserDefaults.standard.string(forKey: "JanitorTestLog")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.janitor.app.test"), object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.object as? String else { return }
            Task { @MainActor in self?.runTestCommand(command) }
        }
    }

    private func runTestCommand(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "shutdown":
            if let device = sims.first(where: { $0.udid == parts[1].uppercased() }) { shutDown(device) }
            else { log("Test: no booted simulator \(parts[1]) in Janitor's list") }
        case "quit", "forcequit":
            if let row = rows.first(where: { String($0.pid) == parts[1] }) { quit(row, force: parts[0] == "forcequit") }
            else { log("Test: no process \(parts[1]) in Janitor's list") }
        default: break
        }
    }

    private func log(_ text: String) {
        if let testLogPath, let handle = FileHandle(forWritingAtPath: testLogPath) {
            handle.seekToEndOfFile()
            handle.write((text + "\n").data(using: .utf8)!)
            try? handle.close()
        }
        events.insert(JanitorEvent(text: text), at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }
}

enum Format {
    static func cpu(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
