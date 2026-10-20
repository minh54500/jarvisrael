import AppKit
import IOKit.ps

/// Onglet Dev : les serveurs de dev qui écoutent en local, et la santé du Mac (CPU, mémoire,
/// batterie, chaleur). Rafraîchi toutes les 3 s tant que l'onglet est ouvert.
@MainActor
final class DevMonitor: ObservableObject {
    static let shared = DevMonitor()

    struct Server: Identifiable, Equatable {
        let pid: Int32
        let port: Int
        let command: String
        var project = ""
        var id: String { "\(pid):\(port)" }
    }

    struct Health: Equatable {
        var cpu: Double?  // 0…1, connu après deux mesures
        var memory = 0.0  // 0…1
        var battery: Int?  // nil sur un Mac sans batterie
        var charging = false
        var thermal = ProcessInfo.ThermalState.nominal
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var health = Health()
    @Published private(set) var scanned = false
    private var timer: Timer?
    private var ticks: (busy: UInt64, total: UInt64)?
    private let queue = DispatchQueue(label: "encoche.dev")

    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { DevMonitor.shared.refresh() }
        }
    }

    func refresh() {
        health = sample()
        queue.async {
            let list = Self.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DevMonitor.shared.servers = list
                    DevMonitor.shared.scanned = true
                }
            }
        }
    }

    func open(_ s: Server) {
        if let url = URL(string: "http://localhost:\(s.port)") { NSWorkspace.shared.open(url) }
    }

    func stop(_ s: Server) {
        kill(s.pid, SIGTERM)
        servers.removeAll { $0.pid == s.pid }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    // MARK: Santé du Mac

    /// Une mesure (le CPU se calcule entre deux mesures successives).
    func sample() -> Health {
        var h = Health(thermal: ProcessInfo.processInfo.thermalState)

        var load = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) }
        }
        if ok == KERN_SUCCESS {
            let t = load.cpu_ticks  // utilisateur, système, repos, nice
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3), total = busy + UInt64(t.2)
            if let last = ticks, total > last.total { h.cpu = Double(busy - last.busy) / Double(total - last.total) }
            ticks = (busy, total)
        }
        if h.cpu == nil { h.cpu = health.cpu }

        var vm = vm_statistics64()
        var m = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmOK = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(m)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &m) }
        }
        if vmOK == KERN_SUCCESS {
            // Comme le Moniteur d'activité : mémoire des apps + câblée + compressée.
            let pages = Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
            h.memory = clamp(pages * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory), 0, 1)
        }

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
                else { continue }
                h.battery = cur * 100 / max
                h.charging = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            }
        }
        return h
    }

    // MARK: Serveurs

    /// Programmes de dev reconnus (on ne montre pas AirPlay, Spotify, Figma… qui écoutent aussi).
    nonisolated private static let runtimes = ["node", "bun", "deno", "python", "ruby", "php", "java", "go", "dotnet", "rails", "puma",
                                   "uvicorn", "gunicorn", "hypercorn", "flask", "vite", "next", "nuxt", "astro", "esbuild",
                                   "webpack", "hugo", "jekyll", "caddy", "nginx", "httpd", "postgres", "mysqld", "mariadbd",
                                   "redis", "mongod", "com.docker", "docker", "ollama", "beam.smp", "cargo", "wrangler", "supabase"]

    nonisolated private static func scan() -> [Server] {
        var found: [Server] = []
        var pid: Int32 = 0, command = ""
        for line in run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let port = Int(value.split(separator: ":").last ?? ""), port < 49152,
                      runtimes.contains(where: { command.lowercased().hasPrefix($0) }), !embedded(pid),
                      !found.contains(where: { $0.pid == pid && $0.port == port })
                else { continue }
                found.append(Server(pid: pid, port: port, command: command))
            default: break
            }
        }
        guard !found.isEmpty else { return [] }
        // Dossier de travail de chaque serveur = le projet.
        var folders: [Int32: String] = [:], cur: Int32 = 0
        let pids = Set(found.map(\.pid)).map(String.init).joined(separator: ",")
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids, "-Fpn"]).split(separator: "\n") {
            if line.first == "p" { cur = Int32(line.dropFirst()) ?? 0 }
            if line.first == "n" { folders[cur] = String(line.dropFirst()) }
        }
        let home = NSHomeDirectory()
        return found.map { s in
            var s = s
            if let f = folders[s.pid] { s.project = f == home ? "~" : URL(fileURLWithPath: f).lastPathComponent }
            return s
        }.sorted { $0.port < $1.port }
    }

    /// Programme embarqué dans une app (le node de Raycast, de VS Code…) : ce n'est pas ton serveur.
    nonisolated private static func embedded(_ pid: Int32) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        let home = NSHomeDirectory()
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") || path.hasPrefix("/System/")
            || path.contains("/Library/Application Support/com.")
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
