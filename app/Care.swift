import AppKit

/// Le bonhomme prend soin de toi : pause toutes les 50 min d'activité, un verre d'eau toutes les
/// 90 min, « va dormir » la nuit, batterie faible, Mac qui chauffe. Désactivable dans le menu.
enum Reminder: Equatable {
    case pause, water, night(Int), battery(Int), heat
}

@MainActor
final class Care {
    static let shared = Care()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "care") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "care"); reset() }
    }

    // Réglages (fenêtre Réglages) : chaque rappel se coupe à part, les durées se choisissent.
    private func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    var pauseMinutes: Int { UserDefaults.standard.object(forKey: "care.pauseMin") as? Int ?? 50 }
    var waterMinutes: Int { UserDefaults.standard.object(forKey: "care.waterMin") as? Int ?? 90 }

    private var activeSince = Date()
    private var lastWater = Date()
    private var nightShown = Date.distantPast
    private var batteryWarned = false
    private var heatWarned = Date.distantPast
    private var timer: Timer?

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Care.shared.tick() }
        }
    }

    /// « Plus tard » : la pause revient dans 10 minutes.
    func snooze() { activeSince = Date().addingTimeInterval(-Double(max(0, pauseMinutes - 10)) * 60) }

    private func reset() {
        activeSince = Date()
        lastWater = Date()
    }

    private func tick() {
        guard enabled else { return }
        let now = Date()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 5 * 60 { activeSince = now }  // tu as déjà fait une pause
        if idle > 20 * 60 { lastWater = now }
        guard idle < 60 else { return }  // personne devant l'écran : on ne dit rien

        let health = DevMonitor.shared.sample()
        if on("care.health"), let b = health.battery {
            if health.charging { batteryWarned = false }
            if b <= 15 && !health.charging && !batteryWarned, Store.shared.remind(.battery(b)) { batteryWarned = true; return }
        }
        if on("care.health"), health.thermal == .serious || health.thermal == .critical, now.timeIntervalSince(heatWarned) > 30 * 60,
           Store.shared.remind(.heat) { heatWarned = now; return }

        let hour = Calendar.current.component(.hour, from: now)
        if on("care.night"), (1..<5).contains(hour), now.timeIntervalSince(nightShown) > 12 * 3600,
           Store.shared.remind(.night(hour)) { nightShown = now; return }

        if on("care.pause"), now.timeIntervalSince(activeSince) >= Double(pauseMinutes) * 60, Store.shared.remind(.pause) {
            activeSince = now
            return
        }
        if on("care.water"), now.timeIntervalSince(lastWater) >= Double(waterMinutes) * 60, Store.shared.remind(.water) { lastWater = now }
    }
}
