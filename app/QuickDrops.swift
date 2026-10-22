// SPDX-License-Identifier: GPL-3.0-or-later
// La forme des gouttes et leur placement viennent de l'« accès rapide » de Vorssaint
// (https://github.com/vorssaint/vorssaint-utils, GPL-3.0), adaptés à Encoche.

import AppKit
import SwiftUI

/// Les gouttes : des boutons ronds qui coulent hors de l'encoche ouverte, sur ses côtés et dessous.
/// Elles sortent quand l'encoche s'ouvre et rentrent quand elle se ferme.
enum QuickAction: CaseIterable {
    case capture, mirror, awake, settings, dnd, music

    enum Side { case left, right, bottom }

    var side: Side {
        switch self {
        case .capture, .mirror, .awake: .left
        case .settings, .dnd: .right
        case .music: .bottom
        }
    }

    @MainActor var symbol: String {
        switch self {
        case .capture: "viewfinder"
        case .mirror: "camera.fill"
        case .awake: Awake.shared.active ? "cup.and.saucer.fill" : "cup.and.saucer"
        case .settings: "gearshape.fill"
        case .dnd: Store.shared.dnd ? "moon.fill" : "moon"
        case .music: Spotify.shared.playing ? "pause.fill" : "play.fill"
        }
    }

    @MainActor var title: String {
        switch self {
        case .capture: "Capturer une zone de l'écran"
        case .mirror: "Miroir : ta caméra"
        case .awake: Awake.shared.active ? "Mac éveillé (reste \(Awake.shared.remaining)) : clic pour changer ou arrêter" : "Garder le Mac éveillé"
        case .settings: "Réglages"
        case .dnd: Store.shared.dnd ? "Ne pas déranger : activé (clic pour le couper)" : "Ne pas déranger"
        case .music: Spotify.shared.playing ? "Mettre la musique en pause" : "Lancer la musique"
        }
    }

    /// Allumée (teinte) : le mode en cours ou la page ouverte.
    @MainActor var tint: Color? {
        let store = Store.shared
        switch self {
        case .dnd where store.dnd: return Color(hex: "#A78BFA")
        case .awake where Awake.shared.active: return Color(hex: "#F7B32B")
        case .mirror where store.view == .dev && store.tool == .mirror: return Color(hex: "#FF8BC4")
        case .music where Spotify.shared.playing: return Color(hex: "#1DB954")
        default: return nil
        }
    }

    @MainActor func run() {
        let store = Store.shared
        switch self {
        case .capture: store.capture()
        case .mirror:
            if store.view == .dev && store.tool == .mirror { store.goTo(store.defaultView) } else { store.openTool(.mirror) }
        case .awake: break  // un menu (voir QuickDropButton)
        case .settings: SettingsWindow.show()
        case .dnd: store.setDND(!store.dnd)
        case .music: Spotify.shared.playPause()
        }
    }
}

enum QuickDropsLayout {
    static let diameter: CGFloat = 40
    static let gap: CGFloat = 10
    static let rowSpacing: CGFloat = 50

    /// Centre d'une goutte : collée au bord à 0, à sa place à 1 (un peu plus loin pendant le rebond).
    static func center(index: Int, progress: CGFloat, edge: CGFloat, top: CGFloat, side: QuickAction.Side) -> CGPoint {
        let phase = progress.isFinite ? min(1.1, max(0, progress)) : 0
        let offset = -14 + phase * (14 + gap + diameter / 2)
        if side == .bottom { return CGPoint(x: top + CGFloat(index) * rowSpacing, y: edge + offset) }
        return CGPoint(x: edge + (side == .left ? -offset : offset), y: top + CGFloat(index) * rowSpacing)
    }

    struct Placement: Identifiable {
        let action: QuickAction
        let index: Int
        let edge: CGFloat  // le bord de l'encoche d'où elle sort
        let top: CGFloat   // où commence sa colonne (ou sa rangée, dessous)
        var id: QuickAction { action }
        func center(_ progress: CGFloat) -> CGPoint {
            QuickDropsLayout.center(index: index, progress: progress, edge: edge, top: top, side: action.side)
        }
    }

    /// Les gouttes autour de l'encoche ouverte, dans le repère du panneau.
    @MainActor static func placements() -> [Placement] {
        let store = Store.shared
        let w = Store.expandedWidth, h = store.viewHeight
        let left = Store.panelSize.width / 2 - w / 2, right = left + w
        let sideTop = store.notch.height + 26
        var indices: [QuickAction.Side: Int] = [:]
        let bottomCount = QuickAction.allCases.filter { $0.side == .bottom }.count
        return QuickAction.allCases.map { action in
            let index = indices[action.side, default: 0]
            indices[action.side] = index + 1
            switch action.side {
            case .left: return Placement(action: action, index: index, edge: left, top: sideTop)
            case .right: return Placement(action: action, index: index, edge: right, top: sideTop)
            case .bottom:
                return Placement(action: action, index: index, edge: h,
                                 top: Store.panelSize.width / 2 - CGFloat(bottomCount - 1) * rowSpacing / 2)
            }
        }
    }

    /// Les ronds cliquables, pour savoir si la souris est « dans » l'encoche.
    @MainActor static func hitRects() -> [CGRect] {
        placements().map { p in
            let c = p.center(1), r = diameter / 2 + 4
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        }
    }
}

/// Le mouvement des gouttes : sortie en ressort à l'ouverture, retour rapide à la fermeture.
@MainActor
final class QuickDropsMotion: ObservableObject {
    static let shared = QuickDropsMotion()
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var interactive = false
    private var generation = 0

    func setVisible(_ visible: Bool) {
        generation += 1
        let token = generation
        interactive = false
        let animation: Animation = visible ? .spring(duration: 0.42, bounce: 0.18).delay(0.12) : .easeIn(duration: 0.14)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            progress = visible ? 1 : 0
        } completion: {
            guard self.generation == token else { return }
            self.interactive = visible
        }
    }
}

/// La goutte qui sort de l'encoche : un rond relié au bord par un col qui s'amincit puis disparaît.
struct QuickDropShape: Shape {
    var progress: CGFloat
    let index: Int
    var edge: CGFloat
    var top: CGFloat
    let side: QuickAction.Side

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(edge, top)) }
        set { progress = newValue.first; edge = newValue.second.first; top = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let phase = min(1.1, max(0, progress))
        guard phase > 0.001 else { return Path() }
        // Tout se dessine comme à gauche, puis se retourne pour la droite et le dessous.
        let anchor = side == .bottom ? rect.height - edge : side == .left ? edge : rect.width - edge
        let center = QuickDropsLayout.center(index: index, progress: phase, edge: anchor, top: top, side: .left)
        let radius = QuickDropsLayout.diameter / 2 * (0.4 + 0.6 * phase)
        var path = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        // Le col fond avant que le rond ait fini de bouger ; son autre bout est sous l'encoche, sans couture.
        let neck = radius * max(0, 1 - phase / 0.84)
        if neck > 0, center.x + radius < anchor {
            path.move(to: CGPoint(x: anchor + 2, y: center.y + neck))
            path.addCurve(to: CGPoint(x: center.x + radius * 0.55, y: center.y + neck * 0.75),
                          control1: CGPoint(x: anchor - 7, y: center.y + neck),
                          control2: CGPoint(x: center.x + radius, y: center.y + neck * 0.15))
            path.addLine(to: CGPoint(x: center.x + radius * 0.55, y: center.y - neck * 0.75))
            path.addCurve(to: CGPoint(x: anchor + 2, y: center.y - neck),
                          control1: CGPoint(x: center.x + radius, y: center.y - neck * 0.15),
                          control2: CGPoint(x: anchor - 7, y: center.y - neck))
            path.closeSubpath()
        }
        if side == .bottom { return path.applying(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: rect.height)) }
        if side == .right { return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0)) }
        return path
    }
}

/// Le calque des gouttes, sur tout le panneau (l'encoche reste dessinée par IslandRoot).
struct QuickDropsView: View {
    @ObservedObject var store: Store
    @ObservedObject var motion = QuickDropsMotion.shared
    @ObservedObject var spotify = Spotify.shared
    @ObservedObject var awake = Awake.shared

    var body: some View {
        let placements = QuickDropsLayout.placements()
        ZStack(alignment: .topLeading) {
            ZStack {
                ForEach(placements) { p in
                    QuickDropShape(progress: motion.progress, index: p.index, edge: p.edge, top: p.top, side: p.action.side)
                        .fill(.black)
                }
            }
            .allowsHitTesting(false)
            ForEach(placements) { p in
                QuickDropButton(action: p.action)
                    .scaleEffect(0.4 + 0.6 * motion.progress)
                    .opacity(Double(min(1, motion.progress)))
                    .position(p.center(motion.progress))
            }
        }
        .frame(width: Store.panelSize.width, height: Store.panelSize.height, alignment: .topLeading)
        .allowsHitTesting(motion.interactive)
        .accessibilityHidden(!motion.interactive)
        .environment(\.colorScheme, .dark)
    }
}

private struct QuickDropButton: View {
    let action: QuickAction
    @State private var hover = false

    var body: some View {
        if action == .awake { AwakeMenu(label: label).onHover { hover = $0 } } else { Button { action.run() } label: { label }.buttonStyle(.plain) .onHover { hover = $0 }
            .help(action.title).accessibilityLabel(action.title) }
    }

    private var label: some View {
        let tint = action.tint
        return Image(systemName: action.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint ?? (hover ? Color.ink : Color.soft))
                .frame(width: QuickDropsLayout.diameter, height: QuickDropsLayout.diameter)
                .background(Circle().fill(hover ? Color(hex: "#1C1D22") : Color.black))
                .overlay(Circle().strokeBorder((tint ?? .white).opacity(tint == nil ? (hover ? 0.22 : 0.12) : 0.5), lineWidth: 0.75))
                .contentShape(Circle())
                .scaleEffect(hover ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// La goutte « éveil » : un menu avec les durées et le mode capot fermé.
private struct AwakeMenu<Label: View>: View {
    let label: Label
    @ObservedObject var awake = Awake.shared

    var body: some View {
        Menu {
            if awake.active {
                Button("Arrêter (reste \(awake.remaining))") { awake.stop() }
                Divider()
            }
            Section(awake.active ? "Changer la durée" : "Garder le Mac éveillé") {
                Button("30 minutes") { awake.start(minutes: 30) }
                Button("1 heure") { awake.start(minutes: 60) }
                Button("2 heures") { awake.start(minutes: 120) }
                Button("4 heures") { awake.start(minutes: 240) }
                Button("Sans limite") { awake.start(minutes: nil) }
            }
            Divider()
            Toggle(awake.lidReady ? "Même capot fermé" : "Même capot fermé (mot de passe une fois)",
                   isOn: Binding(get: { awake.lidMode && awake.lidReady }, set: { awake.setLidMode($0) }))
        } label: { label }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(QuickAction.awake.title)
        .accessibilityLabel(QuickAction.awake.title)
    }
}
