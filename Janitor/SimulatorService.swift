import Foundation

struct SimDevice: Identifiable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    var cpu: Double = 0
    var memory: UInt64 = 0
    var processCount: Int = 0
    /// Why the device counts as in use right now, or nil when it is idle.
    var inUseReason: String?
    /// When the current idle stretch began.
    var idleSince: Date?

    var id: String { udid }

    var usageText: String {
        if let inUseReason { return "in use: \(inUseReason)" }
        guard let idleSince else { return "idle" }
        return "idle \(Format.duration(Date().timeIntervalSince(idleSince)))"
    }
}

/// Thin wrapper over `xcrun simctl`.
enum SimulatorService {
    static let simulatorBundleID = "com.apple.iphonesimulator"

    static func bootedDevices() async -> [SimDevice] {
        let (status, data) = await run(["simctl", "list", "devices", "booted", "-j"])
        guard status == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var devices: [SimDevice] = []
        for (runtimeID, list) in runtimes {
            for entry in list where (entry["state"] as? String) == "Booted" {
                guard let udid = entry["udid"] as? String else { continue }
                devices.append(SimDevice(udid: udid.uppercased(),
                                         name: entry["name"] as? String ?? "Simulator",
                                         runtime: prettyRuntime(runtimeID)))
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    @discardableResult
    static func shutdown(_ udid: String) async -> Bool {
        await run(["simctl", "shutdown", udid]).0 == 0
    }

    @discardableResult
    static func shutdownAll() async -> Bool {
        await run(["simctl", "shutdown", "all"]).0 == 0
    }

    /// Shut-down devices and how much disk their data uses, for "Erase idle simulators".
    static func shutdownDevices() async -> [(device: SimDevice, dataBytes: Int64)] {
        let (status, data) = await run(["simctl", "list", "devices", "-j"])
        guard status == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [(SimDevice, Int64)] = []
        for (runtimeID, list) in runtimes {
            for entry in list where (entry["state"] as? String) == "Shutdown" && (entry["isAvailable"] as? Bool) != false {
                guard let udid = entry["udid"] as? String else { continue }
                let size = (entry["dataPathSize"] as? NSNumber)?.int64Value ?? 0
                out.append((SimDevice(udid: udid.uppercased(), name: entry["name"] as? String ?? "Simulator",
                                      runtime: prettyRuntime(runtimeID)), size))
            }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// Wipes a shut-down device back to factory state (installed apps and their data are removed).
    @discardableResult
    static func erase(_ udid: String) async -> Bool {
        await run(["simctl", "erase", udid]).0 == 0
    }

    static func eraseBlocking(_ udid: String) -> Bool {
        Shell.run("/usr/bin/xcrun", ["simctl", "erase", udid], timeout: 120)?.status == 0
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> "iOS 26.5"
    private static func prettyRuntime(_ id: String) -> String {
        let tail = id.components(separatedBy: "SimRuntime.").last ?? id
        var parts = tail.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return id }
        let platform = parts.removeFirst()
        return parts.isEmpty ? platform : "\(platform) \(parts.joined(separator: "."))"
    }

    private static func run(_ arguments: [String]) async -> (Int32, Data) {
        await Task.detached(priority: .utility) {
            // simctl can hang when the machine is overloaded; give up rather than block forever.
            guard let result = Shell.run("/usr/bin/xcrun", arguments, timeout: 90) else { return (Int32(-1), Data()) }
            return (result.status, result.output)
        }.value
    }
}
