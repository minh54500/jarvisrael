import AppKit
import SwiftUI

/// Spotify dans l'encoche : ce qui joue (Spotify l'annonce lui-même à chaque changement)
/// et les commandes (AppleScript, via osascript pour ne jamais bloquer l'animation).
@MainActor
final class Spotify: ObservableObject {
    static let shared = Spotify()
    static let bundleID = "com.spotify.client"

    struct Track: Equatable {
        var id = "", name = "", artist = "", album = ""
        var duration = 0.0  // secondes
    }

    @Published private(set) var running = false
    @Published private(set) var playing = false
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    /// Encoche n'a pas le droit de piloter Spotify (Réglages Système → Automatisation).
    @Published private(set) var denied = false

    /// Position connue à un instant donné ; entre deux annonces, on avance avec l'horloge.
    private var position = 0.0
    private var positionAt = Date()
    private var artworkFor = ""
    private let queue = DispatchQueue(label: "encoche.spotify")

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { Spotify.shared.apply(info) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Spotify.bundleID else { return }
            MainActor.assumeIsolated { Spotify.shared.running = true }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Spotify.bundleID else { return }
            MainActor.assumeIsolated { Spotify.shared.clear(running: false) }
        }
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if running { refresh() }
    }

    func position(at now: Date) -> Double {
        guard let track else { return 0 }
        let p = playing ? position + now.timeIntervalSince(positionAt) : position
        return clamp(p, 0, track.duration)
    }

    // MARK: Commandes

    func playPause() {
        if track != nil {
            position = position(at: Date())
            positionAt = Date()
            playing.toggle()  // tout de suite, sans attendre la confirmation de Spotify
        }
        tell("playpause")
    }

    func next() { tell("next track") }
    func previous() { tell("previous track") }

    func seek(to seconds: Double) {
        position = seconds
        positionAt = Date()
        objectWillChange.send()
        tell("set player position to \(Int(seconds))")
    }

    /// Fait passer Spotify devant (l'ouvre s'il est fermé).
    func open() {
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: Self.bundleID) {
            ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://open.spotify.com") {
            ws.open(web)
        }
    }

    /// Relit tout l'état dans Spotify (au démarrage, ou quand le panneau s'ouvre).
    func refresh() {
        guard running else { return }
        run("""
            if application id "\(Self.bundleID)" is running then
              tell application id "\(Self.bundleID)"
                try
                  set t to current track
                  return (player state as string) & linefeed & (id of t) & linefeed & (name of t) & linefeed & (artist of t) ¬
                    & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position as string) & linefeed & (artwork url of t)
                on error
                  return (player state as string)
                end try
              end tell
            end if
            return ""
            """) { out in
            let f = out.components(separatedBy: "\n")
            guard f.count >= 8 else { return self.clear(running: self.running) }
            self.playing = f[0] == "playing"
            self.track = Track(id: f[1], name: f[2], artist: f[3], album: f[4], duration: (Double(f[5]) ?? 0) / 1000)
            self.position = Double(f[6].replacingOccurrences(of: ",", with: ".")) ?? 0  // virgule en français
            self.positionAt = Date()
            self.loadArtwork(f[7], for: f[1])
        }
    }

    // MARK: Annonces de Spotify

    private func apply(_ info: [AnyHashable: Any]) {
        running = true
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped" else { return clear(running: true) }
        let id = info["Track ID"] as? String ?? ""
        playing = state == "Playing"
        track = Track(id: id, name: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                      album: info["Album"] as? String ?? "", duration: (info["Duration"] as? Double ?? 0) / 1000)
        if let p = info["Playback Position"] as? Double { position = p }
        positionAt = Date()
        if id != artworkFor {
            artworkFor = id
            artwork = nil
            run("tell application id \"\(Self.bundleID)\" to return artwork url of current track") { self.loadArtwork($0, for: id) }
        }
    }

    private func clear(running: Bool) {
        self.running = running
        playing = false
        track = nil
        artwork = nil
        artworkFor = ""
    }

    private func loadArtwork(_ link: String, for id: String) {
        artworkFor = id
        guard let url = URL(string: link), url.scheme == "https" else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if Spotify.shared.track?.id == id { Spotify.shared.artwork = img }
                }
            }
        }.resume()
    }

    // MARK: AppleScript

    private func tell(_ command: String) {
        run("tell application id \"\(Self.bundleID)\" to \(command)")
    }

    private func run(_ source: String, then done: @escaping @MainActor (String) -> Void = { _ in }) {
        queue.async {
            let r = Self.osascript(source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Spotify.shared.denied = r.denied
                    if r.ok { done(r.out) }
                }
            }
        }
    }

    nonisolated private static func osascript(_ source: String) -> (out: String, ok: Bool, denied: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ("", false, false) }
        var text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if text.hasSuffix("\n") { text.removeLast() }
        // -1743 : l'utilisateur a refusé (ou pas encore accordé) l'Automatisation de Spotify.
        return (text, p.terminationStatus == 0, error.contains("-1743"))
    }
}
