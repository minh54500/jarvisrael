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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var renderer: Renderer!
    private var bridge: Bridge!
    private var timer: Timer?
    private var wasPressed = false
    private var dragCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { setUp() }
    }

    @MainActor private func setUp() {
        let store = Store.shared
        store.notch = notchSize(on: Self.notchScreen)
        renderer = Renderer(store: store)

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: IslandRoot(store: store, renderer: renderer))
        place()
        panel.orderFrontRegardless()

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

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Store.shared.notch = self?.notchSize(on: Self.notchScreen) ?? Store.shared.notch
                self?.place()
            }
        }
        // Petit bonjour au premier lancement
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { store.expandDefault() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { store.collapse() }
    }

    private static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func notchSize(on screen: NSScreen) -> CGSize {
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            return CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 184, height: NSStatusBar.system.thickness + 8)
    }

    private func place() {
        let s = Self.notchScreen.frame, size = Store.panelSize
        panel.setFrame(NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Suivi de la souris (60 fois par seconde) : survol, regard du Mochi, fichiers glissés vers l'encoche.
    @MainActor private func track() {
        let store = Store.shared
        let m = NSEvent.mouseLocation, f = panel.frame
        let p = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        let target = store.islandTarget
        var hit = CGRect(x: Renderer.centerX - target.width / 2, y: 0, width: target.width, height: target.height)
        if store.mode != .expanded { hit = hit.insetBy(dx: -6, dy: 0); hit.size.height += 6 }
        let inside = hit.contains(p) && m.y <= f.maxY + 1
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        store.setHover(inside)
        store.pointerMoved(to: p, mochiCenter: store.mode == .expanded ? renderer.mochiCenter : nil)

        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let pb = NSPasteboard(name: .drag)
        if pressed && !wasPressed { dragCount = pb.changeCount }
        wasPressed = pressed
        let filesDragged = pressed && pb.changeCount != dragCount && (pb.types?.contains(.fileURL) ?? false)
        store.setFileDrag(filesDragged && p.y < 230 && abs(p.x - Renderer.centerX) < 340)
    }
}
