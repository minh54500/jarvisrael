import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Musique jouée au lancement d'Encoche : le jingle livré avec l'app (assets/jingle.*), ou un fichier
/// choisi dans les Réglages, copié chez Encoche (il marche même si l'original est déplacé).
/// Activée par défaut ; muette si les sons de l'app sont coupés. Un clic sur le bonhomme la coupe.
@MainActor
enum LaunchMusic {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "launch.on") as? Bool ?? true }
    static var volume: Float { Float(UserDefaults.standard.object(forKey: "launch.volume") as? Double ?? 0.6) }
    static var file: URL? { custom ?? bundled }

    /// Le fichier choisi par l'utilisateur, s'il en a choisi un.
    static var custom: URL? {
        guard let path = UserDefaults.standard.string(forKey: "launch.file"), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Le jingle d'Encoche, dans l'app.
    static var bundled: URL? {
        Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: nil)?
            .first { $0.deletingPathExtension().lastPathComponent == "jingle" }
    }

    /// Revenir au jingle d'Encoche.
    static func reset() {
        if let c = custom { try? FileManager.default.removeItem(at: c) }
        UserDefaults.standard.removeObject(forKey: "launch.file")
        UserDefaults.standard.removeObject(forKey: "launch.name")
    }
    static var playing: Bool { player?.isPlaying ?? false }

    private static var player: AVAudioPlayer?

    /// Fenêtre de choix ; renvoie le nom du fichier gardé.
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choisis la musique qu'Encoche jouera à son lancement"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let src = panel.url else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: Bridge.folder, withIntermediateDirectories: true)
        if let old = custom { try? fm.removeItem(at: old) }
        let dst = Bridge.folder.appendingPathComponent("Musique de lancement." + src.pathExtension)
        try? fm.removeItem(at: dst)
        guard (try? fm.copyItem(at: src, to: dst)) != nil else { return nil }
        UserDefaults.standard.set(dst.path, forKey: "launch.file")
        UserDefaults.standard.set(src.lastPathComponent, forKey: "launch.name")
        return src.lastPathComponent
    }

    /// Joue le fichier ; renvoie sa durée (0 s'il n'y en a pas).
    @discardableResult
    static func play() -> Double {
        guard let file, let p = try? AVAudioPlayer(contentsOf: file) else { return 0 }
        p.volume = volume
        p.play()
        player = p
        return p.duration
    }

    /// Coupe en fondu (pas de coupure sèche au milieu d'une note).
    static func stop() {
        guard let p = player else { return }
        p.setVolume(0, fadeDuration: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            p.stop()
            if player === p { player = nil }
        }
    }

    static func setVolume(_ v: Double) { player?.volume = Float(v) }
}
