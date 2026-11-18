import SwiftUI

enum ProcFilter: String, CaseIterable, Identifiable {
    /// Anything doing real work right now; keeps the list short and cheap to redraw.
    case active = "Active"
    case all = "All"
    case hogs = "Hogs"
    case simulators = "Simulators"
    case apps = "Apps"
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @State private var filter: ProcFilter = .active
    @State private var search = ""
    @State private var selection: pid_t?
    @State private var sortOrder = [KeyPathComparator(\ProcRow.cpu, order: .reverse)]
    @State private var frozenOrder: [pid_t]?

    private var visibleRows: [ProcRow] {
        var rows = monitor.rows
        switch filter {
        case .active: rows = rows.filter { $0.cpu >= 1 }
        case .all: break
        case .hogs: rows = rows.filter(monitor.isHog)
        case .simulators: rows = rows.filter { $0.kind == .simulator || $0.kind == .emulator }
        case .apps: rows = rows.filter { $0.kind == .app }
        }
        if !search.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search }
        }
        let sorted = rows.sorted(using: sortOrder)
        // While the pointer is over the list, hold every row in place so a Quit button
        // can't slide onto a different process between aiming and clicking.
        guard let frozenOrder else { return sorted }
        let position = Dictionary(uniqueKeysWithValues: frozenOrder.enumerated().map { ($1, $0) })
        return sorted.sorted { (position[$0.pid] ?? Int.max) < (position[$1.pid] ?? Int.max) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                NoticeBanner()
                SummaryBar()
                SystemPressureBar()
                SimulatorSection()
            }
            .padding(16)

            Divider()
            processTable
        }
        .searchable(text: $search, prompt: "Filter processes")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(ProcFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { openWindow(id: "cleanup") } label: { Label("Disk Cleanup", systemImage: "externaldrive.badge.minus") }
                    .help("Preview and delete old Xcode build folders")
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
    }

    private var processTable: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { row in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.shared.icon(for: row))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(row.name).lineLimit(1)
                    if monitor.isHog(row) {
                        Text("HOG")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            TableColumn("CPU", value: \.cpu) { row in
                Text(Format.cpu(row.cpu))
                    .monospacedDigit()
                    .foregroundStyle(row.cpu >= monitor.hogThreshold ? .orange : .primary)
            }
            .width(70)
            TableColumn("Memory", value: \.memory) { row in
                Text(Format.memory(row.memory)).monospacedDigit()
            }
            .width(90)
            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind.rawValue).foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("") { row in
                Button("Quit") { monitor.quit(row) }
                    .controlSize(.small)
            }
            .width(54)
        }
        .onHover { inside in
            frozenOrder = inside ? visibleRows.map(\.pid) : nil
        }
        .onChange(of: sortOrder) { frozenOrder = nil }
        .onChange(of: filter) { frozenOrder = nil }
        .onChange(of: search) { frozenOrder = nil }
        .contextMenu(forSelectionType: pid_t.self) { pids in
            if let pid = pids.first, let row = monitor.rows.first(where: { $0.pid == pid }) {
                Button("Quit \(row.name)") { monitor.quit(row) }
                Button("Force Quit \(row.name)") { monitor.quit(row, force: true) }
                if !row.path.isEmpty {
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(row.path, inFileViewerRootedAtPath: "")
                    }
                }
            }
        }
    }
}

// MARK: - Summary

struct NoticeBanner: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        if let notice = monitor.notice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(notice).lineLimit(2)
                Spacer()
                Button("Dismiss") { monitor.dismissNotice() }.controlSize(.small)
            }
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct SummaryBar: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        HStack(spacing: 12) {
            StatTile(title: "System CPU", value: "\(Int(monitor.totalCPU.rounded()))%") {
                Sparkline(values: monitor.cpuHistory)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(height: 24)
            }
            StatTile(title: "Simulators",
                     value: monitor.sims.isEmpty ? "None" : "\(monitor.sims.count) running") {
                Text(monitor.sims.isEmpty
                     ? "Nothing to clean"
                     : "\(Format.cpu(monitor.simCPU)) CPU · \(Format.memory(monitor.simMemory))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            StatTile(title: "CPU Hogs", value: "\(monitor.hogs.count)") {
                HStack {
                    Text("Background, over \(Int(monitor.hogThreshold))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if monitor.hogs.contains(where: { $0.simUDID == nil }) {
                        Button("Quit All") { monitor.quitAllHogs() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

struct StatTile<Detail: View>: View {
    let title: String
    let value: String
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            detail.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Sparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(max(values.count - 1, 1))
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + CGFloat(index) * step,
                                y: rect.maxY - rect.height * CGFloat(min(max(value, 0), 100) / 100))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Simulators

struct SimulatorSection: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        if !monitor.sims.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Running Simulators").font(.headline)
                    if monitor.autoShutdown {
                        Text("shut down automatically after \(monitor.idleMinutes) min idle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Shut Down All", role: .destructive) {
                        Task { await monitor.shutDownAllSimulators() }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                    ForEach(monitor.sims) { SimulatorCard(device: $0) }
                }
            }
        }
    }
}

struct SimulatorCard: View {
    @Environment(Monitor.self) private var monitor
    let device: SimDevice

    var body: some View {
        let closing = monitor.shuttingDown.contains(device.udid)
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).fontWeight(.medium).lineLimit(1)
                Text("\(device.runtime) · \(Format.cpu(device.cpu)) CPU · \(Format.memory(device.memory)) · \(device.usageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if closing {
                ProgressView().controlSize(.small)
            } else {
                Button("Shut Down") { monitor.shutDown(device) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Icons

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for row: ProcRow) -> NSImage {
        guard !row.path.isEmpty else { return generic }
        // Use the enclosing .app bundle's icon when the binary lives inside one.
        var key = row.path
        if let range = row.path.range(of: ".app/") {
            key = String(row.path[..<range.lowerBound]) + ".app"
        } else {
            return generic
        }
        if let hit = cache[key] { return hit }
        let image = NSWorkspace.shared.icon(forFile: key)
        cache[key] = image
        return image
    }
}
