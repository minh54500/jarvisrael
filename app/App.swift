import AppKit
import SwiftUI

@main
struct EncocheApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// Le premier clic sur un bouton doit marcher même si l'app n'est pas au premier plan.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panneau collé en haut de l'écran, au-dessus de la barre des menus.
/// Il ne prend le clavier que pendant qu'on écrit dans l'encoche (les boutons ne le prennent jamais).
final class NotchPanel: NSPanel {
    private var wantsKeyboard = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { wantsKeyboard }
    override var canBecomeMain: Bool { false }

    func takeKeyboard() {
        wantsKeyboard = true
        makeKey()
    }

    /// Rend le clavier à l'app de devant : un panneau qui ne s'active pas le lui rend en se retirant
    /// un instant de l'écran (le temps d'une seule opération, invisible).
    func releaseKeyboard() {
        wantsKeyboard = false
        guard isKeyWindow else { return }
        makeFirstResponder(nil)
        orderOut(nil)
        orderFrontRegardless()
    }

    /// Une autre app a pris le clavier.
    override func resignKey() {
        super.resignKey()
        wantsKeyboard = false
        makeFirstResponder(nil)
        MainActor.assumeIsolated { Store.shared.keyboardLost() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var bridge: Bridge!
    private var timer: Timer?
    private var wasPressed = false
    private var dragCount = 0
    /// Empêche App Nap : sans ça, macOS endort l'app (pas de fenêtre au premier plan)
    /// et l'animation tombe à quelques images par seconde.
    private var noNap: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                      reason: "Animation de l'encoche")
        // Sons rendus en tâche de fond, moteur audio prêt avant la première animation.
        DispatchQueue.global(qos: .utility).async {
            _ = Sound.shared
            DispatchQueue.main.async { Sound.shared.warmUp() }
        }
        MainActor.assumeIsolated { setUp() }
    }

    @MainActor private func setUp() {
        let store = Store.shared
        store.notch = notchSize(on: Self.notchScreen)

        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: IslandRoot(store: store))
        host.sizingOptions = []
        panel.contentView = host
        place()
        panel.orderFrontRegardless()
        store.releaseKeyboard = { [weak self] in self?.panel.releaseKeyboard() }

        bridge = Bridge { event, responder in
            MainActor.assumeIsolated { Store.shared.handle(event, responder) }
        }
        bridge.start()
        Bridge.installHookScript()
        store.refreshHooked()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        if ProcessInfo.processInfo.environment["ENCOCHE_FPS"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let p = self?.panel else { return }
                    print("fenêtre visible : \(p.occlusionState.contains(.visible)) · à l'écran : \(p.isVisible) · mode : \(Store.shared.mode)")
                    fflush(stdout)
                }
            }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Store.shared.notch = self.notchSize(on: Self.notchScreen)
                self.place()
            }
        }
    }

    private static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Taille exacte de l'encoche matérielle (ou d'une encoche « virtuelle » sur un écran sans encoche).
    private func notchSize(on screen: NSScreen) -> CGSize {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 184, height: max(24, NSApp.mainMenu?.menuBarHeight ?? 24))
    }

    @MainActor private func place() {
        let s = Self.notchScreen.frame, size = Store.panelSize
        panel.setFrame(NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Suivi de la souris (60 fois par seconde) : survol, regard du Mochi, fichiers glissés vers l'encoche.
    @MainActor private func track() {
        let store = Store.shared
        let m = NSEvent.mouseLocation, f = panel.frame
        let p = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        let target = store.islandTarget
        var hit = CGRect(x: f.width / 2 - target.width / 2, y: 0, width: target.width, height: target.height)
        if store.mode != .expanded { hit = hit.insetBy(dx: -8, dy: 0); hit.size.height += 4 }
        let inside = hit.contains(p) && m.y <= f.maxY + 2
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        store.setHover(inside)
        store.pointerMoved(to: p, mochiCenter: store.mode == .expanded ? store.mochiCenterInPanel : nil)

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let pb = NSPasteboard(name: .drag)
        if pressed && !wasPressed { dragCount = pb.changeCount }
        if !pressed && wasPressed { store.mouseReleased() }
        wasPressed = pressed
        let filesDragged = pressed && pb.changeCount != dragCount && (pb.types?.contains(.fileURL) ?? false)
        store.setFileDrag(filesDragged && p.y < 230 && abs(p.x - f.width / 2) < 340)
    }
}
