import Foundation
import UserNotifications

/// Headless entry points. `Janitor --cleanup` is what the launchd agent runs every two hours.
enum CleanupCLI {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if arguments.contains("--install-agent") {
            let error = LaunchAgent.install()
            print(error ?? "Installed: \(LaunchAgent.label) runs every 2 hours")
            return error == nil ? 0 : 1
        }
        if arguments.contains("--uninstall-agent") {
            LaunchAgent.uninstall()
            print("Removed \(LaunchAgent.label)")
            return 0
        }
        if arguments.contains("--agent-status") {
            print(LaunchAgent.isInstalled ? "installed and loaded" : "not installed")
            return 0
        }
        if let udid = value(after: "--erase-simulator") {
            let ok = SimulatorService.eraseBlocking(udid)
            print(ok ? "erased \(udid)" : "could not erase \(udid)")
            return ok ? 0 : 1
        }
        guard arguments.contains("--cleanup") else { return nil }

        var config = CleanupConfig.live
        if let root = value(after: "--test-root") {
            config = .test(root: URL(fileURLWithPath: root))
        }
        if let gb = value(after: "--assume-free-gb").flatMap(Int64.init) {
            config.assumedFreeBytes = gb * CleanupPolicy.gib
        }

        if arguments.contains("--dry-run") {
            let plan = Cleaner.plan(config: config, estimateSizes: !arguments.contains("--no-sizes"))
            print("DRY RUN: nothing is deleted.")
            print("Free disk \(Format.disk(plan.freeBytes)); low-disk mode \(plan.lowDisk ? "ON (6 hour limit)" : "off")")
            if !plan.inUseCheckReliable { print("WARNING: could not list open files/processes; everything is kept.") }
            for item in plan.items {
                let age = Format.duration(Date().timeIntervalSince(item.lastUsed))
                switch item.verdict {
                case .delete:
                    let size = item.estimatedBytes.map { "about " + Format.disk($0) } ?? "size not measured"
                    print("WOULD DELETE  \(item.url.path)  [last used \(age) ago, \(size)]")
                case .keep(let reason):
                    print("KEEP          \(item.url.path)  [\(reason)]")
                }
            }
            print("\(plan.deletions.count) of \(plan.items.count) folders would be deleted, about \(Format.disk(plan.estimatedBytes)).")
            return 0
        }

        let result = Cleaner.clean(config: config, trigger: arguments.contains("--scheduled") ? "scheduled" : "command line")
        if let blocked = result.blocked {
            print("Nothing deleted: \(blocked)")
            return 1
        }
        for item in result.deleted { print("DELETED  \(item.url.path)") }
        for (item, reason) in result.skipped { print("SKIPPED  \(item.url.path)  [\(reason)]") }
        print("Free disk \(Format.disk(result.freeBefore)) -> \(Format.disk(result.freeAfter)) (df change \(Format.disk(result.freedBytes)))")

        if config.assumedFreeBytes == nil, result.freeAfter < CleanupPolicy.criticalDiskBytes, value(after: "--test-root") == nil {
            LowDiskNotifier.postBlocking(freeBytes: result.freeAfter)
        }
        return 0
    }
}

/// The launchd agent that runs the cleanup every two hours.
enum LaunchAgent {
    static let label = "com.janitor.app.cleanup"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var domain: String { "gui/\(getuid())" }

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return false }
        return Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 20)?.status == 0
    }

    /// Returns nil on success, or what went wrong.
    static func install() -> String? {
        // Point at the installed copy when there is one, so the schedule survives rebuilds.
        let installed = "/Applications/Janitor.app/Contents/MacOS/Janitor"
        guard let program = FileManager.default.isExecutableFile(atPath: installed) ? installed : Bundle.main.executablePath else {
            return "Could not find the Janitor executable."
        }
        let logs = CleanupConfig.live.logDirectory
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program, "--cleanup", "--scheduled"],
            "StartInterval": 7200,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": logs.appendingPathComponent("scheduled-run.log").path,
            "StandardErrorPath": logs.appendingPathComponent("scheduled-run.log").path,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            return "Could not write \(plistURL.path): \(error.localizedDescription)"
        }
        _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 20)
        guard Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path], timeout: 20)?.status == 0 else {
            return "launchctl refused to load the schedule."
        }
        return nil
    }

    static func uninstall() {
        _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 20)
        try? FileManager.default.removeItem(at: plistURL)
    }
}

/// "Disk almost full" notification with a Clean Now action.
enum LowDiskNotifier {
    static let category = "LOW_DISK"
    static let cleanAction = "CLEAN_NOW"
    private static let lastPostedKey = "lowDiskLastNotified"

    static func registerCategory() {
        let action = UNNotificationAction(identifier: cleanAction, title: "Clean Now", options: [.foreground])
        let category = UNNotificationCategory(identifier: category, actions: [action], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Posts at most once every six hours.
    static func post(freeBytes: Int64, completion: (() -> Void)? = nil) {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastPostedKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { completion?(); return }
        defaults.set(Date().timeIntervalSince1970, forKey: lastPostedKey)

        let content = UNMutableNotificationContent()
        content.title = "Disk almost full"
        content.body = "Only \(Format.disk(freeBytes)) free. Janitor can clear old Xcode build folders."
        content.categoryIdentifier = category
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-disk", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in completion?() }
    }

    /// For the command-line run, which exits right after.
    static func postBlocking(freeBytes: Int64) {
        registerCategory()
        let done = DispatchSemaphore(value: 0)
        post(freeBytes: freeBytes) { done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }
}
