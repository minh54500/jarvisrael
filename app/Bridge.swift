import Foundation

// Serveur local (socket Unix) qui reçoit les événements envoyés par hook.py.
// Une demande de permission garde sa connexion ouverte jusqu'à la réponse de l'utilisateur.

final class Responder {
    private var fd: Int32
    init(fd: Int32) { self.fd = fd }

    func reply(_ object: [String: Any]) {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: object) else { return close() }
        data.append(0x0A)
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, data.count) }
        close()
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit { close() }
}

final class Bridge {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Encoche")
    static let socketPath = folder.appendingPathComponent("encoche.sock").path

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    /// File série : les événements sont lus et transmis dans l'ordre où ils arrivent.
    private let queue = DispatchQueue(label: "encoche.bridge")
    private let onEvent: ([String: Any], Responder?) -> Void

    init(onEvent: @escaping ([String: Any], Responder?) -> Void) { self.onEvent = onEvent }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        unlink(Self.socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in path.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: c) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listenFD, 16) == 0 else { return }
        chmod(Self.socketPath, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        do {
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf[n - 1] == 0x0A || data.count > 4_000_000 { break }
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Darwin.close(fd)
                return
            }
            let blocking = (obj["hook_event_name"] as? String) == "PermissionRequest"
            let responder = blocking ? Responder(fd: fd) : nil
            if !blocking { Darwin.close(fd) }
            DispatchQueue.main.async { self.onEvent(obj, responder) }
        }
    }

    // MARK: Brancher / débrancher Claude Code (~/.claude/settings.json)

    static var hookScript: URL { folder.appendingPathComponent("hook.py") }

    /// Copie hook.py hors de l'app (son chemin reste stable entre les mises à jour).
    static func installHookScript() {
        guard let src = Bundle.main.url(forResource: "hook", withExtension: "py") else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: hookScript)
        try? FileManager.default.copyItem(at: src, to: hookScript)
    }

    /// Lance hook.py --install / --uninstall / --status ; renvoie sa sortie.
    @discardableResult
    static func runHookTool(_ flag: String) -> (ok: Bool, output: String) {
        installHookScript()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [hookScript.path, flag]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
