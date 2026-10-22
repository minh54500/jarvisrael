// SPDX-License-Identifier: GPL-3.0-or-later
// Le mode « capot fermé » (règle sudo limitée à pmset disablesleep, remise en route après un plantage,
// remise en veille si le capot est déjà fermé) suit celui de Vorssaint
// (https://github.com/vorssaint/vorssaint-utils, GPL-3.0), adapté à Encoche.

import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Garder le Mac éveillé un moment (30 min, 1 h…, ou sans limite), et au choix même capot fermé.
///
/// Écran ouvert, une simple demande à macOS suffit. Capot fermé, macOS endort le Mac quoi qu'on demande :
/// seul `pmset disablesleep 1` l'en empêche. Il faut l'administrateur : Encoche installe une fois une règle
/// qui n'autorise que `pmset disablesleep 0` et `1`, sans mot de passe. Garde-fous : l'intention est notée
/// avant d'agir (un plantage est réparé au lancement suivant), tout est remis à la fermeture de l'app,
/// et le mode s'arrête seul sur batterie faible (un Mac éveillé dans un sac se vide et chauffe).
@MainActor
final class Awake: ObservableObject {
    static let shared = Awake()

    @Published private(set) var until: Date?        // fin prévue (distantFuture : sans limite)
    @Published private(set) var lidReady = false    // la règle « capot fermé » est installée
    @Published private(set) var problem: String?
    var active: Bool { until != nil }
    var lidMode: Bool { UserDefaults.standard.bool(forKey: "awake.lid") }

    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var timer: Timer?
    private var lidOn = false

    static let rulePath = "/etc/sudoers.d/encoche-clamshell"
    /// Tous les « pmset » passent l'un après l'autre, dans l'ordre demandé : sinon un « allume » puis un « éteins »
    /// rapprochés (ou un essai au lancement pendant une réparation) pourraient se croiser et laisser le Mac sans veille.
    private static let queue = DispatchQueue(label: "encoche.awake.pmset")
    private static let flag = "awake.sleepDisabled"  // « disablesleep 1 » posé par Encoche, pas encore retiré

    /// Au lancement : un plantage a pu laisser le Mac incapable de dormir capot fermé. On répare.
    func recover() {
        if UserDefaults.standard.bool(forKey: Self.flag) {  // d'abord la réparation, puis l'essai de la règle (même file)
            Self.queue.async {
                let ok = Self.pmset(false) || !Self.sleepDisabledNow()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if ok { UserDefaults.standard.set(false, forKey: Self.flag) } else { Awake.shared.restoreWithPassword() }
                    }
                }
            }
        }
        refreshLidReady()
    }

    func refreshLidReady(then next: (@MainActor () -> Void)? = nil) {
        Self.queue.async {
            // On l'essaie pour de vrai : on remet l'état actuel, ce qui ne change rien au système.
            let ready = Self.pmset(Self.sleepDisabledNow())
            DispatchQueue.main.async { MainActor.assumeIsolated { Awake.shared.lidReady = ready; next?() } }
        }
    }

    /// `minutes` nil : sans limite.
    func start(minutes: Int?) {
        stop(silent: true)
        until = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        take(&systemAssertion, "PreventUserIdleSystemSleep")
        take(&displayAssertion, "PreventUserIdleDisplaySleep")
        if lidMode && lidReady { setLid(true) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Awake.shared.tick() }
        }
        Sound.shared.play("tick")
        Store.shared.say(lidMode && lidReady ? "Mac éveillé \(label), même capot fermé" : "Mac éveillé \(label)", ok: true)
    }

    func stop(silent: Bool = false) {
        guard active else { return }
        until = nil
        timer?.invalidate()
        timer = nil
        release(&systemAssertion)
        release(&displayAssertion)
        if lidOn { setLid(false) }
        if !silent { Store.shared.say("Le Mac peut de nouveau se mettre en veille", ok: true) }
    }

    /// À la fermeture d'Encoche : tout redevient normal, tout de suite.
    func stopForQuit() {
        release(&systemAssertion)
        release(&displayAssertion)
        if lidOn || UserDefaults.standard.bool(forKey: Self.flag) {
            // Après ce qui attend encore dans la file (un « allume » en route ne passera pas après nous).
            let ok = Self.queue.sync { Self.pmset(false) }
            if ok { UserDefaults.standard.set(false, forKey: Self.flag) }
        }
    }

    func setLidMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "awake.lid")
        objectWillChange.send()
        if on && !lidReady { return installRule() }
        if active { setLid(on && lidReady) }
    }

    /// « 1 h 12 », « 25 min », « sans limite » : ce qui reste.
    var remaining: String {
        guard let until else { return "" }
        if until == .distantFuture { return "sans limite" }
        let m = max(1, Int(until.timeIntervalSinceNow / 60))
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    private var label: String {
        guard let until else { return "" }
        if until == .distantFuture { return "sans limite" }
        let m = Int((until.timeIntervalSinceNow / 60).rounded())
        return m >= 60 ? "pendant \(m / 60) h" + (m % 60 > 0 ? " \(m % 60)" : "") : "pendant \(m) min"
    }

    private func tick() {
        if let until, until != .distantFuture, until <= Date() { return stop() }
        // Capot fermé sur batterie faible : on arrête avant que le Mac ne se vide (ou ne chauffe dans un sac).
        let h = DevMonitor.shared.sample()
        if lidOn, let b = h.battery, !h.charging, b <= 15 {
            stop(silent: true)
            Store.shared.showToast(Toast(icon: "battery.25", color: "#F7B32B", title: "Éveil arrêté",
                                         text: "batterie à \(b) % : le Mac peut de nouveau dormir"))
        }
        objectWillChange.send()  // le temps qui reste
    }

    private func take(_ id: inout IOPMAssertionID, _ type: String) {
        guard id == 0 else { return }
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Encoche : garder le Mac éveillé" as CFString, &id)
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    // MARK: Capot fermé

    private func setLid(_ on: Bool) {
        if on { UserDefaults.standard.set(true, forKey: Self.flag) }  // noté avant d'agir : un plantage sera réparé
        lidOn = on
        Self.queue.async {
            let ok = Self.pmset(on)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let awake = Awake.shared
                    if !on && ok {
                        UserDefaults.standard.set(false, forKey: Self.flag)
                        Self.sleepIfLidClosed()
                    }
                    if !ok {
                        awake.problem = on ? "Le mode capot fermé n'a pas pu s'activer." : "Le Mac n'a pas pu retrouver sa veille normale."
                        if !on { awake.restoreWithPassword() }
                    }
                }
            }
        }
    }

    /// La règle sudo, installée une fois avec le mot de passe administrateur.
    private func installRule() {
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
        let command = "mkdir -p /etc/sudoers.d && chmod 0755 /etc/sudoers.d && echo '\(rule)' > \(Self.rulePath) && chmod 0440 \(Self.rulePath) && /usr/sbin/visudo -c -f \(Self.rulePath) || { rm -f \(Self.rulePath); exit 1; }"
        Self.admin(command, prompt: "Encoche va créer une règle limitée (seulement « pmset disablesleep ») pour garder le Mac éveillé capot fermé sans te redemander ton mot de passe. C'est la seule fois.") { ok in
            let awake = Awake.shared
            guard ok else {
                UserDefaults.standard.set(false, forKey: "awake.lid")
                awake.problem = "Mode capot fermé pas installé."
                awake.objectWillChange.send()
                return awake.refreshLidReady()
            }
            awake.problem = nil
            // Une fois la règle vérifiée : si l'éveil tourne déjà, le capot fermé s'y ajoute.
            awake.refreshLidReady { if awake.active && awake.lidMode && awake.lidReady { awake.setLid(true) } }
        }
    }

    func removeRule() {
        if lidOn { setLid(false) }
        UserDefaults.standard.set(false, forKey: "awake.lid")
        Self.admin("rm -f \(Self.rulePath)", prompt: "Encoche va retirer sa règle « capot fermé ».") { _ in Awake.shared.refreshLidReady() }
    }

    /// Dernier recours : remettre la veille normale en demandant le mot de passe.
    private func restoreWithPassword() {
        Self.admin("pmset disablesleep 0", prompt: "Encoche doit remettre la mise en veille normale du Mac.") { ok in
            if ok { UserDefaults.standard.set(false, forKey: Self.flag) }
        }
    }

    nonisolated private static func pmset(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "disablesleep", on ? "1" : "0"]).status == 0
    }

    nonisolated private static func sleepDisabledNow() -> Bool {
        run("/usr/bin/pmset", ["-g"]).output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Une commande en administrateur, avec la fenêtre de mot de passe de macOS (Encoche passe devant
    /// pour qu'elle ne s'ouvre pas derrière une autre app).
    private static func admin(_ command: String, prompt: String, done: @escaping @MainActor (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let source = "do shell script \(quoted(command)) with administrator privileges with prompt \(quoted(prompt))"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let ok = NSAppleScript(source: source)?.executeAndReturnError(&error) != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    /// Capot déjà fermé quand le mode s'arrête : macOS ne regarde le capot qu'à l'ouverture ou à la
    /// fermeture, donc on demande nous-mêmes la veille qu'il aurait provoquée.
    private static func sleepIfLidClosed(attempts: Int = 8) {
        guard lidClosed() else { return }
        let root = IOPMFindPowerManagement(kIOMainPortDefault)
        guard root != 0 else { return }
        let result = IOPMSleepSystem(root)
        IOServiceClose(root)
        if result != kIOReturnSuccess && attempts > 1 {  // pmset rend la main avant que la veille soit permise
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { sleepIfLidClosed(attempts: attempts - 1) } }
        }
    }

    private static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }
}
