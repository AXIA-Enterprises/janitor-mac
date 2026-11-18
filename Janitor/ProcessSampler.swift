import Darwin
import Foundation

enum ProcKind: String, CaseIterable, Comparable {
    case simulator = "Simulator"
    case emulator = "Emulator"
    case app = "App"
    case background = "Background"

    static func < (a: ProcKind, b: ProcKind) -> Bool { a.rawValue < b.rawValue }
}

struct ProcRow: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    /// Activity Monitor style: 100 == one full core.
    let cpu: Double
    let memory: UInt64
    var kind: ProcKind
    /// Booted simulator this process belongs to, if any.
    var simUDID: String?
    /// How long this process has been continuously above the hog threshold.
    let hogSeconds: Double
    let isFrontmost: Bool

    var id: pid_t { pid }

    /// An app the developer installed on a simulator (as opposed to the simulated OS itself).
    var isUserSimApp: Bool { simUDID != nil && path.contains("/Containers/Bundle/Application/") }
}

/// What the main thread knows about GUI apps, handed to the sampler each tick.
struct AppInfo {
    let name: String
    let isRegular: Bool
    let isFrontmost: Bool
}

struct Snapshot {
    var rows: [ProcRow] = []
    /// System-wide CPU load, 0...100.
    var totalCPU: Double = 0
    /// launchd_sim pid -> device UDID
    var simRoots: [pid_t: String] = [:]
    /// Full command lines of running xcodebuild / xctest processes.
    var buildCommands: [String] = []
}

/// Reads per-process CPU and memory straight from libproc (same source Activity Monitor uses).
/// Only processes owned by the current user are visible without root, which is also
/// exactly the set we are able to quit.
actor ProcessSampler {
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var lastWall: UInt64 = 0
    private var lastHost: (busy: UInt64, total: UInt64) = (0, 0)
    private var pathCache: [pid_t: (comm: String, path: String)] = [:]
    private var simRootCache: [pid_t: String] = [:]
    private var hogTime: [pid_t: Double] = [:]
    private var argCache: [pid_t: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = (UInt64(tb.numer), UInt64(tb.denom))
    }

    func sample(apps: [pid_t: AppInfo], hogThreshold: Double) -> Snapshot {
        let now = mach_absolute_time()
        let wallTicks = lastWall == 0 ? 0 : now - lastWall
        let wallSeconds = Double(wallTicks * timebase.numer / timebase.denom) / 1e9
        lastWall = now

        struct Raw {
            let pid: pid_t, ppid: pid_t
            let name: String, path: String
            let cpu: Double, memory: UInt64
        }

        var raws: [Raw] = []
        var parents: [pid_t: pid_t] = [:]
        var newCPUTime: [pid_t: UInt64] = [:]
        var simRoots: [pid_t: String] = [:]
        var buildCommands: [String] = []

        for pid in Self.allPIDs() where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            let ppid = pid_t(bsd.pbi_ppid)
            parents[pid] = ppid

            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue } // not ours (root/other user)

            // rusage times are in mach ticks, which are not nanoseconds on Apple silicon.
            let cpuTicks = usage.ri_user_time + usage.ri_system_time
            newCPUTime[pid] = cpuTicks
            var cpu = 0.0
            if let prev = lastCPUTime[pid], wallTicks > 0, cpuTicks >= prev {
                cpu = Double(cpuTicks - prev) / Double(wallTicks) * 100
            }

            // The kernel's short name is read fresh every tick: a pid can exec into a different
            // program (simulator-trampoline becomes launchd_sim), which must invalidate the cached path.
            let comm = withUnsafeBytes(of: bsd.pbi_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let path = self.path(for: pid, comm: comm)
            var name = (path as NSString).lastPathComponent
            if name.isEmpty { name = comm }
            if name.isEmpty { name = "pid \(pid)" }

            if comm == "xcodebuild" || comm == "xctest" {
                if let args = argCache[pid] ?? Self.arguments(of: pid) {
                    argCache[pid] = args
                    buildCommands.append(args)
                }
            }

            if comm == "launchd_sim" {
                if let udid = simRootCache[pid] ?? Self.simulatorUDID(forLaunchdSim: pid) {
                    simRootCache[pid] = udid
                    simRoots[pid] = udid
                }
            }

            raws.append(Raw(pid: pid, ppid: ppid, name: name, path: path,
                            cpu: cpu, memory: usage.ri_phys_footprint))
        }

        // Drop caches for processes that are gone.
        lastCPUTime = newCPUTime
        pathCache = pathCache.filter { newCPUTime[$0.key] != nil }
        simRootCache = simRootCache.filter { newCPUTime[$0.key] != nil }
        argCache = argCache.filter { newCPUTime[$0.key] != nil }

        // Every process in a simulator descends from that device's launchd_sim.
        var ownerMemo: [pid_t: String?] = [:]
        func owner(of pid: pid_t) -> String? {
            if let known = ownerMemo[pid] { return known }
            var chain: [pid_t] = []
            var cur = pid
            var result: String? = nil
            while cur > 1, chain.count < 64 {
                if let udid = simRoots[cur] { result = udid; break }
                if let known = ownerMemo[cur] { result = known; break }
                chain.append(cur)
                guard let next = parents[cur], next != cur else { break }
                cur = next
            }
            for p in chain { ownerMemo[p] = result }
            return result
        }

        var newHog: [pid_t: Double] = [:]
        var snapshot = Snapshot()
        snapshot.simRoots = simRoots
        snapshot.buildCommands = buildCommands
        snapshot.rows = raws.map { raw in
            let udid = owner(of: raw.pid)
            let app = apps[raw.pid]
            let kind: ProcKind
            if udid != nil {
                kind = .simulator
            } else if raw.name.hasPrefix("qemu-system") {
                kind = .emulator
            } else if app?.isRegular == true {
                kind = .app
            } else {
                kind = .background
            }
            var hog = 0.0
            if raw.cpu >= hogThreshold {
                hog = (hogTime[raw.pid] ?? 0) + wallSeconds
                newHog[raw.pid] = hog
            }
            return ProcRow(pid: raw.pid, ppid: raw.ppid,
                           name: app?.name ?? raw.name, path: raw.path,
                           cpu: raw.cpu, memory: raw.memory, kind: kind,
                           simUDID: udid, hogSeconds: hog,
                           isFrontmost: app?.isFrontmost ?? false)
        }
        hogTime = newHog

        let host = Self.hostCPUTicks()
        if lastHost.total > 0, host.total > lastHost.total {
            snapshot.totalCPU = Double(host.busy - lastHost.busy) / Double(host.total - lastHost.total) * 100
        }
        lastHost = host
        return snapshot
    }

    private func path(for pid: pid_t, comm: String) -> String {
        if let cached = pathCache[pid], cached.comm == comm { return cached.path }
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = len > 0 ? String(cString: buffer) : ""
        pathCache[pid] = (comm, path)
        return path
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// A process's arguments and environment, one per line.
    private static func arguments(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(size).map { $0 == 0 ? UInt8(ascii: "\n") : $0 }, as: UTF8.self)
    }

    /// launchd_sim carries its device path in its arguments/environment; pull the UDID out of it.
    private static func simulatorUDID(forLaunchdSim pid: pid_t) -> String? {
        guard let text = arguments(of: pid) else { return nil }
        let pattern = #"CoreSimulator/Devices/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).uppercased()
    }

    private static func hostCPUTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }
}
