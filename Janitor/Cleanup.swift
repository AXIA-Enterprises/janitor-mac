import Foundation

// MARK: - Where and when

/// Every path the cleaner may touch is derived from these two roots, so a test run can
/// point the whole thing at a throwaway directory tree.
struct CleanupConfig {
    var home: URL
    var tmp: URL
    /// Test override for "how much disk is free", to exercise low-disk mode.
    var assumedFreeBytes: Int64?

    static var live: CleanupConfig {
        CleanupConfig(home: URL(fileURLWithPath: NSHomeDirectory()), tmp: URL(fileURLWithPath: "/private/tmp"))
    }

    static func test(root: URL) -> CleanupConfig {
        CleanupConfig(home: root.appendingPathComponent("home"), tmp: root.appendingPathComponent("private/tmp"))
    }

    var derivedDataRoot: URL { home.appendingPathComponent("Library/Developer/Xcode/DerivedData") }
    var buildsRoot: URL { home.appendingPathComponent("Builds") }
    var claudeTmpRoot: URL { tmp.appendingPathComponent("claude-\(getuid())") }
    var logDirectory: URL { home.appendingPathComponent("Library/Logs/Janitor") }
    var logFile: URL { logDirectory.appendingPathComponent("cleanup.log") }
}

enum CleanupKind: String {
    case derivedData = "Xcode DerivedData"
    case scratch = "Session build folder"
    case builds = "Builds DerivedData"
}

enum CleanupPolicy {
    static let gib: Int64 = 1 << 30
    /// Below this, age limits tighten.
    static let lowDiskBytes = 30 * gib
    /// Below this, the app notifies.
    static let criticalDiskBytes = 15 * gib

    static func ageLimit(for kind: CleanupKind, freeBytes: Int64) -> TimeInterval {
        if freeBytes < lowDiskBytes { return 6 * 3600 }
        switch kind {
        case .derivedData, .builds: return 2 * 86400
        case .scratch: return 86400
        }
    }
}

// MARK: - Plan and result

enum CleanupVerdict: Equatable {
    case delete
    case keep(String)

    var willDelete: Bool { self == .delete }
}

struct CleanupItem: Identifiable {
    let id = UUID()
    let url: URL
    let kind: CleanupKind
    let lastUsed: Date
    let ageLimit: TimeInterval
    var verdict: CleanupVerdict
    /// Allocated size, only filled in for previews. An estimate: see `Cleaner.estimatedSize`.
    var estimatedBytes: Int64?
}

struct CleanupPlan {
    var items: [CleanupItem]
    let freeBytes: Int64
    /// False when the open-file / process listing could not be read; nothing is deleted then.
    let inUseCheckReliable: Bool

    var lowDisk: Bool { freeBytes < CleanupPolicy.lowDiskBytes }
    var deletions: [CleanupItem] { items.filter { $0.verdict.willDelete } }
    var estimatedBytes: Int64 { deletions.reduce(0) { $0 + ($1.estimatedBytes ?? 0) } }
}

struct CleanupResult {
    var deleted: [CleanupItem] = []
    var skipped: [(item: CleanupItem, reason: String)] = []
    var freeBefore: Int64 = 0
    var freeAfter: Int64 = 0
    var blocked: String?

    var freedBytes: Int64 { freeAfter - freeBefore }
}

// MARK: - Is a folder in use?

/// One snapshot of every open file and every command line on the machine.
/// A folder is in use if any process has it in its command line or holds a file open under it.
struct InUseIndex {
    let openPaths: [String]
    let commands: [String]
    let reliable: Bool

    static func capture() -> InUseIndex {
        // Command lines. No grep is involved, so there is no search command to match itself;
        // our own process is dropped by pid.
        var commands: [String] = []
        var psOK = false
        if let ps = Shell.run("/bin/ps", ["-A", "-o", "pid=,command="]), ps.status == 0 {
            let own = String(getpid())
            for line in String(decoding: ps.output, as: UTF8.self).split(separator: "\n") {
                let trimmed = line.drop { $0 == " " }
                guard let space = trimmed.firstIndex(of: " ") else { continue }
                if trimmed[..<space] == own { continue }
                commands.append(String(trimmed[trimmed.index(after: space)...]))
            }
            psOK = !commands.isEmpty
        }

        // Open files, working directories and executables of every process we are allowed to
        // see, read straight from the kernel (the same source lsof uses). Listing them all with
        // lsof itself can take minutes on a busy machine; `lsof +D` is still run per folder as
        // the last check before a deletion.
        let paths = openPathsOfAllProcesses()
        return InUseIndex(openPaths: Array(paths), commands: commands, reliable: psOK && paths.count > 50)
    }

    private static func openPathsOfAllProcesses() -> Set<String> {
        var paths = Set<String>()
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return paths }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return paths }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            // Executable
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                paths.insert(String(cString: pathBuffer))
            }
            // Working directory
            var vnodes = proc_vnodepathinfo()
            let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodes, vnodeSize) == vnodeSize {
                let cwd = withUnsafeBytes(of: vnodes.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if !cwd.isEmpty { paths.insert(cwd) }
            }
            // Open file descriptors
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { continue }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
                let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if !path.isEmpty { paths.insert(path) }
            }
        }
        return paths
    }

    /// The prescribed per-folder check, run right before a deletion: `lsof +D <folder>`.
    /// Returns nil when lsof finds nothing open under the folder, otherwise why to skip it.
    static func lsofObjection(to url: URL) -> String? {
        guard let lsof = Shell.run("/usr/sbin/lsof", ["-n", "-P", "-w", "+D", url.path], timeout: 300) else {
            return "lsof +D did not finish, so it could not be confirmed unused"
        }
        let lines = String(decoding: lsof.output, as: UTF8.self).split(separator: "\n")
        if lines.count > 1 { return "in use: lsof +D lists \(lines.count - 1) open file(s)" }
        return nil
    }

    /// Why the folder counts as in use, or nil if nothing references it.
    func holder(of url: URL) -> String? {
        for variant in Self.spellings(of: url) {
            let inside = variant + "/"
            if let open = openPaths.first(where: { $0 == variant || $0.hasPrefix(inside) }) {
                return "a process has \(open.replacingOccurrences(of: inside, with: "…/")) open"
            }
            if let command = commands.first(where: { Self.mentions($0, variant) }) {
                return "referenced by running process: \(command.prefix(60))"
            }
        }
        return nil
    }

    /// The same folder can be written as /tmp/x, /private/tmp/x, or through a symlink.
    private static func spellings(of url: URL) -> Set<String> {
        var out: Set<String> = [url.path]
        if let real = realpath(url.path, nil) {
            out.insert(String(cString: real))
            free(real)
        }
        for path in out where path.hasPrefix("/private/") {
            out.insert(String(path.dropFirst("/private".count)))
        }
        return out
    }

    /// True when `command` contains `path` as a whole path, not as a prefix of a longer name
    /// (".../dd-1" must not match ".../dd-10").
    private static func mentions(_ command: String, _ path: String) -> Bool {
        var searchFrom = command.startIndex
        while let range = command.range(of: path, range: searchFrom..<command.endIndex) {
            if range.upperBound == command.endIndex { return true }
            let next = command[range.upperBound]
            if !(next.isLetter || next.isNumber || next == "-" || next == "_" || next == ".") { return true }
            searchFrom = range.upperBound
        }
        return false
    }
}

// MARK: - The cleaner

enum Cleaner {
    private static let fm = FileManager.default

    /// Works out what would be deleted. Never deletes anything.
    static func plan(config: CleanupConfig, estimateSizes: Bool) -> CleanupPlan {
        let free = config.assumedFreeBytes ?? SystemStats.freeDiskBytes(at: config.home.path) ?? Int64.max
        let index = InUseIndex.capture()
        let now = Date()

        var items = discover(config: config).map { url, kind -> CleanupItem in
            let limit = CleanupPolicy.ageLimit(for: kind, freeBytes: free)
            let used = lastUsed(url)
            var verdict = CleanupVerdict.delete
            if let reason = protectedReason(url) {
                verdict = .keep(reason)
            } else if now.timeIntervalSince(used) < limit {
                verdict = .keep("used \(Format.duration(now.timeIntervalSince(used))) ago, limit is \(Format.duration(limit))")
            } else if !index.reliable {
                verdict = .keep("could not verify it is unused")
            } else if let holder = index.holder(of: url) {
                verdict = .keep("in use: \(holder)")
            }
            return CleanupItem(url: url, kind: kind, lastUsed: used, ageLimit: limit, verdict: verdict)
        }

        if estimateSizes {
            let targets = items.indices.filter { items[$0].verdict.willDelete }
            var sizes = [Int64](repeating: 0, count: targets.count)
            sizes.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: targets.count) { slot in
                    buffer[slot] = estimatedSize(items[targets[slot]].url)
                }
            }
            for (slot, index) in targets.enumerated() { items[index].estimatedBytes = sizes[slot] }
        }

        items.sort { ($0.verdict.willDelete ? 0 : 1, $0.url.path) < ($1.verdict.willDelete ? 0 : 1, $1.url.path) }
        return CleanupPlan(items: items, freeBytes: free, inUseCheckReliable: index.reliable)
    }

    /// Deletes what a fresh plan says is deletable, re-checking each folder immediately before removal.
    static func clean(config: CleanupConfig, trigger: String) -> CleanupResult {
        var result = CleanupResult()
        let log = CleanupLog(config: config)
        guard let lock = RunLock(directory: config.logDirectory) else {
            result.blocked = "another cleanup is already running"
            return result
        }
        defer { lock.release() }

        result.freeBefore = SystemStats.freeDiskBytes(at: config.home.path) ?? 0
        result.freeAfter = result.freeBefore
        let current = plan(config: config, estimateSizes: false)
        log.write("RUN start (\(trigger)); free \(Format.disk(result.freeBefore)); low-disk mode \(current.lowDisk ? "on" : "off"); \(current.deletions.count) of \(current.items.count) folders eligible")
        guard current.inUseCheckReliable else {
            result.blocked = "could not list open files and processes, so nothing was deleted"
            log.write("RUN aborted: \(result.blocked!)")
            return result
        }

        for item in current.deletions {
            // Second look right before deleting: a build may have started since the plan was made.
            let allowed = Set(discover(config: config).map { $0.url.path })
            let fresh = InUseIndex.capture()
            let reason: String?
            if !allowed.contains(item.url.path) { reason = "no longer matches a cleanup location" }
            else if let protected = protectedReason(item.url) { reason = protected }
            else if !fresh.reliable { reason = "could not re-verify it is unused" }
            else if let holder = fresh.holder(of: item.url) { reason = "in use: \(holder)" }
            else if Date().timeIntervalSince(lastUsed(item.url)) < item.ageLimit { reason = "was used again" }
            else if let objection = InUseIndex.lsofObjection(to: item.url) { reason = objection }
            else { reason = remove(item.url) }

            if let reason {
                result.skipped.append((item, reason))
                log.write("SKIP \(item.url.path): \(reason)")
            } else {
                result.deleted.append(item)
                log.write("DELETED \(item.url.path) [\(item.kind.rawValue), last used \(CleanupLog.stamp(item.lastUsed))]")
            }
        }

        if !result.deleted.isEmpty { Thread.sleep(forTimeInterval: 2) } // let APFS settle before measuring
        result.freeAfter = SystemStats.freeDiskBytes(at: config.home.path) ?? result.freeBefore
        log.write("RUN end; deleted \(result.deleted.count), skipped \(result.skipped.count); free \(Format.disk(result.freeBefore)) -> \(Format.disk(result.freeAfter)) (df change \(Format.disk(result.freedBytes)))")
        return result
    }

    // MARK: Discovery

    /// The complete list of folders the cleaner is ever allowed to consider.
    static func discover(config: CleanupConfig) -> [(url: URL, kind: CleanupKind)] {
        var found: [(URL, CleanupKind)] = []

        // ~/Library/Developer/Xcode/DerivedData/*
        for dir in realDirectories(in: config.derivedDataRoot) { found.append((dir, .derivedData)) }

        // /private/tmp/claude-<uid>/*/*/scratchpad/dd-* and dd_*
        for project in realDirectories(in: config.claudeTmpRoot) {
            for session in realDirectories(in: project) {
                for dir in realDirectories(in: session.appendingPathComponent("scratchpad")) {
                    let name = dir.lastPathComponent
                    if name.hasPrefix("dd-") || name.hasPrefix("dd_") { found.append((dir, .scratch)) }
                }
            }
        }

        // /private/tmp/*/dd_*
        for parent in realDirectories(in: config.tmp) {
            for dir in realDirectories(in: parent) where dir.lastPathComponent.hasPrefix("dd_") {
                found.append((dir, .scratch))
            }
        }

        // ~/Builds/*/DerivedData
        for project in realDirectories(in: config.buildsRoot) {
            let dir = project.appendingPathComponent("DerivedData")
            if isRealDirectory(dir) { found.append((dir, .builds)) }
        }
        return found
    }

    private static func realDirectories(in parent: URL) -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return [] }
        return names.sorted().map { parent.appendingPathComponent($0) }.filter(isRealDirectory)
    }

    /// A directory, and not a symlink to one: following a link could lead outside the allowed locations.
    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: Safety

    /// Things that are never deleted, whatever their age.
    static func protectedReason(_ url: URL) -> String? {
        let name = url.lastPathComponent
        let path = url.path
        if name.isEmpty || name == "." || name == ".." { return "protected: not a named folder" }
        if name.localizedCaseInsensitiveContains("Hearth-build") { return "protected: Hearth-build is always kept" }
        if name.lowercased().hasSuffix(".app") { return "protected: app bundle" }
        if path.contains("/.ollama") { return "protected: Ollama data" }
        if path == "/Applications" || path.hasPrefix("/Applications/") { return "protected: Applications" }
        if url.pathComponents.count < 4 { return "protected: too close to the disk root" }
        return nil
    }

    /// Removes one folder. Returns nil on success, or why it failed.
    private static func remove(_ url: URL) -> String? {
        let directory = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        // Same guard as `rm -rf -- "${DIR:?}/${NAME:?}"`: refuse if either half is empty.
        guard !directory.isEmpty, directory != "/", !name.isEmpty, !name.contains("/") else {
            return "refused: unsafe path"
        }
        guard let rm = Shell.run("/bin/rm", ["-rf", "--", directory + "/" + name], timeout: 1800) else {
            return "rm did not finish"
        }
        if fm.fileExists(atPath: url.path) { return "rm exited \(rm.status) and the folder is still there" }
        return nil
    }

    // MARK: Age and size

    /// Newest modification time in the top three levels, plus Xcode's own last-access stamp.
    /// The folder's own date is not enough: it does not change when files deeper down do.
    static func lastUsed(_ url: URL) -> Date {
        var newest = modificationDate(url) ?? .distantPast
        if let plist = NSDictionary(contentsOf: url.appendingPathComponent("info.plist")),
           let accessed = plist["LastAccessedDate"] as? Date {
            newest = max(newest, accessed)
        }
        var visited = 0
        var queue: [(URL, Int)] = [(url, 0)]
        while let (dir, depth) = queue.popLast(), visited < 50_000 {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                visited += 1
                let child = dir.appendingPathComponent(name)
                if let date = modificationDate(child) { newest = max(newest, date) }
                if depth < 2, isRealDirectory(child) { queue.append((child, depth + 1)) }
            }
        }
        return newest
    }

    private static func modificationDate(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    /// Sum of blocks actually allocated. Used only for the preview; the real number after a
    /// clean comes from the free-space change. Skips the compilation cache's sparse store
    /// files, which report tens of GB they do not occupy.
    static func estimatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let name = file.lastPathComponent
            if (name == "data.v1" || name == "index.v1"), file.path.contains("CompilationCache.noindex") { continue }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// MARK: - Support

enum Shell {
    /// Runs a tool with an argument list (no shell, so nothing is word-split or expanded).
    /// Returns nil if it could not start or had to be stopped at the timeout.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 120) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var timedOut = false
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut = true
            kill(process.processIdentifier, SIGKILL) // a tool stuck in the kernel ignores a polite stop
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        if timedOut || process.terminationReason == .uncaughtSignal { return nil }
        return (process.terminationStatus, data)
    }
}

enum SystemStats {
    /// Same figure `df` reports as available.
    static func freeDiskBytes(at path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Same figures as `sysctl vm.swapusage`.
    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }
}

/// Appends to ~/Library/Logs/Janitor/cleanup.log.
struct CleanupLog {
    let config: CleanupConfig

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func write(_ message: String) {
        try? FileManager.default.createDirectory(at: config.logDirectory, withIntermediateDirectories: true)
        let line = "\(Self.stamp(Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: config.logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: config.logFile)
        }
    }
}

/// Stops the app and the scheduled run from cleaning at the same time.
final class RunLock {
    private let descriptor: Int32

    init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent(".cleanup.lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

extension Format {
    static func disk(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
