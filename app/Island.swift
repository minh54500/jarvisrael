import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Forme de l'island (encoche agrandie)

/// Rectangle aux coins bas arrondis, avec deux « ailes » concaves en haut qui se fondent
/// dans le bord de l'écran (les ::before/::after du prototype). Taille et rayons animables.
struct IslandShape: Shape {
    var flare: Double
    var radius: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let k = 0.5523  // quart de cercle en Bézier
        let f = flare, x0 = rect.minX + f, x1 = rect.maxX - f, h = rect.maxY
        let r = max(0, min(radius, rect.height / 2, (x1 - x0) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: 0))
        if f > 0.01 {
            p.addCurve(to: CGPoint(x: x0, y: f), control1: CGPoint(x: rect.minX + f * k, y: 0), control2: CGPoint(x: x0, y: f - f * k))
        }
        p.addLine(to: CGPoint(x: x0, y: h - r))
        p.addCurve(to: CGPoint(x: x0 + r, y: h), control1: CGPoint(x: x0, y: h - r + r * k), control2: CGPoint(x: x0 + r - r * k, y: h))
        p.addLine(to: CGPoint(x: x1 - r, y: h))
        p.addCurve(to: CGPoint(x: x1, y: h - r), control1: CGPoint(x: x1 - r + r * k, y: h), control2: CGPoint(x: x1, y: h - r + r * k))
        p.addLine(to: CGPoint(x: x1, y: f))
        if f > 0.01 {
            p.addCurve(to: CGPoint(x: rect.maxX, y: 0), control1: CGPoint(x: x1, y: f - f * k), control2: CGPoint(x: rect.maxX - f * k, y: 0))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Racine du panneau

struct IslandRoot: View {
    @ObservedObject var store: Store

    var body: some View {
        let size = store.islandTarget
        let flare = store.mode == .hidden ? 0.0 : 14.0
        let radius = store.mode == .expanded ? 30.0 : store.mode == .compact ? 14.0 : 10.0
        ZStack(alignment: .top) {
            IslandShape(flare: flare, radius: radius)
                .fill(Color.black)
                .frame(width: size.width + 2 * flare, height: size.height)
            ZStack(alignment: .topLeading) {
                IslandContent(store: store)
                    .frame(width: size.width, height: size.height, alignment: .top)
                // Un seul minuteur pour tous les personnages : 60 images/s ouverte, 30 en compact.
                TimelineView(.animation(minimumInterval: store.mode == .expanded ? nil : 1.0 / 30,
                                        paused: store.mode == .hidden && store.mochiSlot.hb < 0.5)) { timeline in
                    ZStack(alignment: .topLeading) {
                        MinisView(store: store, frame: timeline.date)
                            .frame(width: 52, height: store.notch.height)
                            .position(x: size.width - 26, y: store.notch.height / 2)
                            .opacity(store.mode == .compact ? 1 : 0)
                        MochiView(store: store, frame: timeline.date)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(IslandShape(flare: 0, radius: radius))
        }
        .frame(width: Store.panelSize.width, height: Store.panelSize.height, alignment: .top)
    }
}

/// Le Mochi, dessiné dans un petit cadre qui le suit (pas dans tout le panneau).
/// `frame` vient du minuteur : l'utiliser dans le Canvas force SwiftUI à le redessiner à chaque image.
struct MochiView: View {
    @ObservedObject var store: Store
    let frame: Date

    var body: some View {
        let slot = store.mochiSlot
        let side = max(1, slot.hb * 4)
        Canvas { [frame] ctx, size in
            _ = frame
            FPS.tick()
            let c = store.mochiCenterInPanel, p = store.pointer
            store.mochi.lookTarget = (tanh((p.x - c.x) / 260), tanh((p.y - c.y) / 200))
            store.mochi.update(CACurrentMediaTime())
            store.mochi.draw(ctx, cx: size.width / 2, cy: size.height / 2, hb: size.height / 4)
        }
        .frame(width: side, height: side)
        .contentShape(Circle().inset(by: side * 0.3))
        .onTapGesture { store.mochiTapped() }
        .contextMenu { SettingsMenu(store: store) }
        .position(x: slot.x, y: slot.y)
        .opacity(slot.hb < 0.5 ? 0 : 1)
    }
}

/// Mini-Mochis des sessions, dans l'oreille droite de l'encoche compacte.
struct MinisView: View {
    @ObservedObject var store: Store
    let frame: Date

    var body: some View {
        Canvas { [frame] ctx, size in
            _ = frame
            guard store.mode == .compact else { return }
            let list = Array(store.sessions.prefix(4))
            guard !list.isEmpty else { return }
            let now = CACurrentMediaTime(), sp = 6.0
            let offsets: [[(Double, Double)]] = [[(0, 0)], [(-sp, 0), (sp, 0)], [(-sp, -sp), (sp, -sp), (0, sp)],
                                                 [(-sp, -sp), (sp, -sp), (-sp, sp), (sp, sp)]]
            for (i, s) in list.enumerated() {
                guard let m = store.minis[s.id] else { continue }
                let o = offsets[list.count - 1][i]
                m.update(now)
                m.draw(ctx, cx: size.width / 2 + o.0, cy: size.height / 2 + o.1, hb: list.count == 1 ? 13 : 7.5)
            }
        }
    }
}

/// Ondes et traînées du coucou d'entrée (greeting-v2). Les points sont regroupés par opacité :
/// une vingtaine de remplissages par image au lieu de 850.
struct GreetingRings: View {
    let store: Store
    let center: CGPoint

    private struct Ring { let t0: Double; let buckets: [(alpha: Double, dots: [(a: Double, j: Double, s: Double)])] }
    private static let data: (rings: [Ring], streaks: [(a: Double, sp: Double, len: Double, t0: Double, col: Color)]) = {
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let rings = [0.10, 0.20, 0.30, 0.45, 0.60].map { t0 -> Ring in
            var buckets: [[(a: Double, j: Double, s: Double)]] = Array(repeating: [], count: 4)
            for _ in 0..<170 {
                let dot = (a: rnd() * 2 * .pi, j: (rnd() - 0.5) * 0.22, s: 0.7 + rnd() * 0.9)
                buckets[min(3, Int(rnd() * 4))].append(dot)
            }
            return Ring(t0: t0, buckets: buckets.enumerated().map { (alpha: 0.5 + Double($0.offset) * 0.15, dots: $0.element) })
        }
        let cols = ["#3B9EFF", "#F29B38", "#FF5A4E", "#2EC4A0", "#A78BFA"]
        let streaks = (0..<16).map { i in
            (a: Double(i) / 16 * 2 * .pi + (rnd() - 0.5) * 0.3, sp: 230 + rnd() * 260, len: 6 + rnd() * 9, t0: 0.08 + rnd() * 0.14, col: Color(hex: cols[i % 5]))
        }
        return (rings, streaks)
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            let frame = timeline.date
            Canvas { ctx, _ in
                _ = frame
                guard let start = store.mochi.greetStart else { return }
                let t = CACurrentMediaTime() - start, cx = center.x, cy = center.y
                for ring in Self.data.rings {
                    let k = seg(t, ring.t0, ring.t0 + 1.35)
                    guard k > 0 && k < 1 else { continue }
                    let rx = lerp(14, 380, Ease.out(k)), ry = rx * 0.34
                    let fade = (1 - k) * (k < 0.08 ? k / 0.08 : 1)
                    for bucket in ring.buckets {
                        var path = Path()
                        for d in bucket.dots {
                            let r = 1 + d.j
                            path.addRect(CGRect(x: cx + cos(d.a) * rx * r, y: cy + sin(d.a) * ry * r, width: d.s, height: d.s))
                        }
                        ctx.fill(path, with: .color(.white.opacity(bucket.alpha * fade)))
                    }
                }
                for s in Self.data.streaks {
                    let k = seg(t, s.t0, s.t0 + 0.6)
                    guard k > 0 && k < 1 else { continue }
                    let dist = s.sp * Ease.out(k) * 0.9 + 10
                    var line = Path()
                    line.move(to: CGPoint(x: cx + cos(s.a) * (dist - s.len), y: cy + sin(s.a) * (dist - s.len) * 0.42))
                    line.addLine(to: CGPoint(x: cx + cos(s.a) * dist, y: cy + sin(s.a) * dist * 0.42))
                    ctx.stroke(line, with: .color(s.col.opacity(1 - k)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct SettingsMenu: View {
    @ObservedObject var store: Store

    var body: some View {
        Button(Sound.shared.on ? "Couper le son" : "Activer le son") {
            Sound.shared.on.toggle()
            store.objectWillChange.send()
        }
        Divider()
        if store.hooked {
            Button("Débrancher de Claude Code") { store.setHooked(false) }
        } else {
            Button("Brancher à Claude Code…") { store.setHooked(true) }
        }
        Button(store.openAtLogin ? "Ne plus ouvrir au démarrage" : "Ouvrir au démarrage") {
            store.setLoginItem(!store.openAtLogin)
        }
        Divider()
        Button("Quitter Encoche") { NSApp.terminate(nil) }
    }
}

// MARK: - Contenu de l'island ouverte

struct IslandContent: View {
    @ObservedObject var store: Store

    var body: some View {
        ZStack(alignment: .top) {
            header
            Group {
                switch store.view {
                case .greeting:
                    Card(wash: .white.opacity(0.06)) {
                        GreetingRings(store: store, center: CGPoint(x: 310, y: 54))
                    }
                case .empty: EmptyPanel(store: store)
                case .overview: OverviewPanel(store: store)
                case .approval: ApprovalPanel(store: store)
                case .finished: FinishedPanel(store: store)
                case .error: ErrorPanel(store: store)
                case .upload: UploadPanel(store: store)
                case .choose: ChoosePanel(store: store)
                case .converting: ConvertingPanel(store: store)
                case .result: ResultPanel(store: store)
                case .shelf: ShelfPanel(store: store)
                case .music: MusicPanel(store: store)
                }
            }
            .id(store.view)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(.easeOut(duration: 0.26).delay(0.1)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
            .padding(.top, store.cardTop)
            .padding([.horizontal, .bottom], 10)
        }
        .frame(width: Store.expandedWidth, height: store.viewHeight, alignment: .top)
        .opacity(store.mode == .expanded ? 1 : 0)
        .animation(store.mode == .expanded ? .easeOut(duration: 0.22).delay(0.06) : .easeIn(duration: 0.1), value: store.mode)
        .allowsHitTesting(store.mode == .expanded)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color.ink)
        .font(Fonts.body)
    }

    /// Bandeau à hauteur de l'encoche : les onglets à gauche de la caméra, l'état et le son à droite.
    private var header: some View {
        HStack(spacing: 0) {
            Tabs(store: store)
            Spacer()
            let n = store.sessions.filter { $0.state == .working || $0.state == .approval || $0.state == .waiting }.count
            if n > 0 {
                HStack(spacing: 5) {
                    PulseDot(color: .success)
                    Text("\(n) en cours").font(Fonts.caption).foregroundStyle(Color.muted)
                }
                .padding(.trailing, 6)
            }
            Button {
                Sound.shared.on.toggle()
                store.objectWillChange.send()
                Sound.shared.play("blip")
            } label: {
                Image(systemName: Sound.shared.on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButton())
            .help(Sound.shared.on ? "Couper le son" : "Activer le son")
            .accessibilityLabel(Sound.shared.on ? "Couper le son" : "Activer le son")
        }
        .padding(.horizontal, 12)
        .frame(height: store.notch.height)
    }
}

// MARK: - Onglets du bandeau

/// Claude · Musique · Étagère. L'onglet actif s'élargit avec son nom ; la pastille glisse de l'un à l'autre.
private struct Tabs: View {
    @ObservedObject var store: Store
    @ObservedObject var spotify = Spotify.shared
    @Namespace private var ns

    private enum Tab { case claude, music, shelf }

    private var current: Tab {
        switch store.view {
        case .music: .music
        case .shelf: .shelf
        default: .claude
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            let busy = store.sessions.contains { $0.state == .working || $0.state == .approval || $0.state == .waiting }
            item(.claude, icon: "sparkle", title: "Claude", badge: nil, live: busy) { store.goToClaude() }
            item(.music, icon: spotify.playing ? "waveform" : "music.note", title: "Musique", badge: nil, live: spotify.playing) {
                store.goTo(.music)
            }
            item(.shelf, icon: store.shelf.isEmpty ? "tray" : "tray.full.fill", title: "Étagère",
                 badge: store.shelf.isEmpty ? nil : "\(store.shelf.count)", live: false) { store.goTo(.shelf) }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: current)
    }

    private func item(_ tab: Tab, icon: String, title: String, badge: String?, live: Bool, action: @escaping () -> Void) -> some View {
        let active = current == tab
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: live && tab == .music)
                if active { Text(title).font(Fonts.labelBold).transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading))) }
                if let badge { Text(badge).font(.system(size: 10.5, weight: .bold)).monospacedDigit() }
            }
            .foregroundStyle(active ? Color.ink : tab == .music && live ? Color.spotify : Color.muted)
            .overlay(alignment: .topTrailing) {
                if live && tab == .claude && !active { Circle().fill(Color.success).frame(width: 5, height: 5).offset(x: 4, y: -2) }
            }
            .padding(.horizontal, active ? 10 : 8)
            .frame(height: 24)
            .background {
                if active { Capsule().fill(.white.opacity(0.13)).matchedGeometryEffect(id: "tab", in: ns) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(HoverDim())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Point qui respire : « quelque chose tourne ».
private struct PulseDot: View {
    let color: Color
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .background(Circle().fill(color.opacity(0.35)).scaleEffect(on && !still ? 2.2 : 1).opacity(on && !still ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

// MARK: - Éléments communs

struct Card<Content: View>: View {
    var wash: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color.surface
                    if let wash {
                        RadialGradient(colors: [wash, .clear], center: UnitPoint(x: 0.5, y: 1.3), startRadius: 0, endRadius: 380)
                    }
                }
                .clipShape(shape)
            }
            // Liseré plus clair en haut : la carte semble éclairée par le dessus, comme du verre.
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct Pill: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, primary: primary) }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(Fonts.button)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .foregroundStyle(primary ? Color.onLight : Color.ink)
            .background(Capsule().fill(primary ? Color.ink.opacity(hover ? 0.88 : 1)
                                               : .white.opacity(configuration.isPressed ? 0.2 : hover ? 0.14 : 0.09)))
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.06)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Bouton-icône rond de 28 pt, éclairé au survol.
struct IconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconBody(configuration: configuration) }
}

private struct IconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(hover ? Color.ink : Color.muted)
            .frame(width: 28, height: 28)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Bouton sans fond : s'éclaircit au survol, se tasse au clic.
private struct HoverDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverDimBody(configuration: configuration) }
}

private struct HoverDimBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .brightness(hover ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct Who: View {
    let session: Session?
    let suffix: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: session?.color ?? "#FFFFFF")).frame(width: 8, height: 8)
            if let session { Text(session.name).fontWeight(.semibold) }
            Text(suffix).foregroundStyle(Color.muted)
        }
        .font(Fonts.label)
        .lineLimit(1)
    }
}

private func big(_ s: String) -> some View {
    Text(s).font(Fonts.title).lineLimit(2)
}

private func sub(_ s: String, red: Bool = false) -> some View {
    Text(s).foregroundStyle(red ? Color.danger : Color.muted).lineLimit(2)
}

// MARK: - Vues

private struct EmptyPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: .white.opacity(0.08)) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    big("Rien ne tourne pour l'instant.")
                    sub(store.hooked ? "Lance Claude Code dans VS Code, ou glisse un fichier sur moi."
                                     : "Branche-moi à Claude Code pour suivre tes sessions d'ici.")
                }
                Spacer()
                if !store.hooked {
                    Button("Brancher à Claude Code") { store.setHooked(true) }.buttonStyle(Pill(primary: true))
                }
            }
            .padding(.leading, 110)
            .padding(.trailing, 18)
        }
    }
}

private struct OverviewPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Who(session: store.focused, suffix: "Claude Code")
                        Spacer(minLength: 4)
                        if let s = store.focused {
                            Button { store.jump(to: s) } label: {
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(IconButton())
                            .help("Ouvrir dans VS Code")
                            .accessibilityLabel("Ouvrir \(s.name) dans VS Code")
                        }
                    }
                    if let notice = store.notice {
                        Text(notice.text)
                            .font(Fonts.lead)
                            .foregroundStyle(notice.ok ? Color.success : Color.danger)
                            .lineLimit(2)
                            .transition(.opacity)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            let lines = Array((store.focused?.history ?? []).suffix(2))
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                let current = i == lines.count - 1
                                Text(current ? (store.focused?.line ?? line) : line)
                                    .font(current ? Fonts.lead : Fonts.label)
                                    .foregroundStyle(current ? Color.ink : Color.faint)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if lines.isEmpty { Text(store.focused?.line ?? "").foregroundStyle(Color.muted) }
                        }
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    ComposeBar(store: store)
                }
                .animation(.easeOut(duration: 0.2), value: store.notice?.text)
                .padding(.leading, 100)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
            }
            .frame(width: 356)
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.sessions.prefix(4)) { s in
                        SessionRow(session: s, chosen: s.id == store.focused?.id, state: label(s.state)) { store.select(s) }
                    }
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func label(_ s: BotState) -> String {
        switch s {
        case .working: "travaille"
        case .approval: "à autoriser"
        case .waiting: "attend ta réponse"
        case .finished: "terminé"
        case .error: "erreur"
        case .sleeping, .idle, .dizzy: "au repos"
        }
    }
}

/// Une session dans la liste de droite : sa couleur, son nom, son état en pastille.
private struct SessionRow: View {
    let session: Session
    let chosen: Bool
    let state: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let tint = Color(hex: STYLES[session.state]?.col ?? "#9A9FA8")
        let busy = session.state == .working || session.state == .approval || session.state == .waiting
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: session.color)).frame(width: 8, height: 8)
                Text(session.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    if busy { PulseDot(color: tint) }
                    Text(state).lineLimit(1)
                }
                .font(Fonts.caption)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(tint.opacity(0.12)))
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous)
                .fill(.white.opacity(chosen ? 0.12 : hover ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(chosen ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .help("Écrire à \(session.name)")
        .accessibilityLabel("\(session.name), \(state)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Champ « Écris à Claude… » et bouton d'envoi, en bas de la section de gauche.
private struct ComposeBar: View {
    @ObservedObject var store: Store
    var body: some View {
        let empty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 6) {
            ComposeField(text: $store.draft,
                         placeholder: store.focused.map { "Écris à Claude (\($0.name))…" } ?? "Écris à Claude…",
                         onSubmit: { store.submitDraft() },
                         onEditing: { store.setComposing($0) })
                .frame(height: 18)
            Button { store.submitDraft() } label: {
                Group {
                    if store.sending { ProgressView().controlSize(.mini).tint(Color.onLight) }
                    else { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)) }
                }
                .foregroundStyle(Color.onLight)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.ink))
            }
            .buttonStyle(.plain)
            .opacity(empty && !store.sending ? 0.3 : 1)
            .disabled(empty || store.sending)
            .help("Envoyer à Claude (Entrée)")
            .accessibilityLabel("Envoyer à Claude")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(store.composing ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(store.composing ? 0.16 : 0.04)))
        .animation(.easeOut(duration: 0.15), value: store.composing)
    }
}

/// Étagère : les fichiers gardés. Glisser = déposer ailleurs ; clic = copier (à coller avec ⌘V).
private struct ShelfPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#3B9EFF", 0.22)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let notice = store.notice {
                        Text(notice.text).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(notice.ok ? Color.success : Color.danger).lineLimit(1)
                    } else {
                        Text(store.shelf.isEmpty ? "Glisse un fichier sur l'encoche pour le garder ici."
                                                 : "Glisse-les où tu veux, ou clique pour copier.")
                            .font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1)
                    }
                    Spacer()
                    if !store.shelf.isEmpty {
                        Button("Vider") { store.clearShelf() }.buttonStyle(Pill())
                    }
                }
                HStack(spacing: 6) {
                    // Les plus récents d'abord ; au-delà de 6, on l'indique.
                    ForEach(store.shelf.suffix(6).reversed(), id: \.self) { url in ShelfItem(store: store, url: url) }
                    if store.shelf.count > 6 {
                        Text("+\(store.shelf.count - 6)").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.muted).padding(.leading, 4)
                    }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
    }
}

private struct ShelfItem: View {
    @ObservedObject var store: Store
    let url: URL
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().interpolation(.high)
                .frame(width: 40, height: 40)
            Text(url.lastPathComponent)
                .font(Fonts.caption)
                .foregroundStyle(Color.soft)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 70, height: 28, alignment: .top)
        }
        .padding(.vertical, 5)
        .frame(width: 78)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { store.unshelve(url) } label: {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(hex: "#3A3D44")))
                }
                .buttonStyle(.plain)
                .help("Retirer de l'étagère")
                .accessibilityLabel("Retirer \(url.lastPathComponent) de l'étagère")
                .offset(x: 3, y: -3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.copyFile(url) }
        .onDrag {
            store.startDragOut()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        }
        .contextMenu {
            Button("Copier") { store.copyFile(url) }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Retirer de l'étagère") { store.unshelve(url) }
        }
        .help(url.path)
    }
}

/// Spotify : pochette, morceau, progression et commandes.
private struct MusicPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var spotify = Spotify.shared

    var body: some View {
        Card(wash: Color(hex: "#1DB954", spotify.playing ? 0.34 : 0.16)) {
            Group {
                if let t = spotify.track { player(t) } else { idle }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
        .animation(.easeOut(duration: 0.4), value: spotify.playing)
    }

    private func player(_ t: Spotify.Track) -> some View {
        HStack(spacing: 14) {
            Button { spotify.open() } label: { cover }
                .buttonStyle(.plain)
                .help("Ouvrir Spotify")
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                if spotify.denied {
                    sub("Autorise Encoche à piloter Spotify : Réglages Système → Confidentialité → Automatisation.", red: true)
                        .font(Fonts.caption)
                } else {
                    Text(t.artist).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                MusicProgress(spotify: spotify)
            }
            .frame(height: 76)
            HStack(spacing: 2) {
                Button { spotify.previous() } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(RoundControl()).help("Morceau précédent").accessibilityLabel("Morceau précédent")
                Button {
                    if !spotify.playing { store.mochi.emote(.happy, 0.8) }
                    spotify.playPause()
                } label: { Image(systemName: spotify.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(RoundControl(primary: true)).help(spotify.playing ? "Pause" : "Lecture")
                    .accessibilityLabel(spotify.playing ? "Pause" : "Lecture")
                Button { spotify.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(RoundControl()).help("Morceau suivant").accessibilityLabel("Morceau suivant")
            }
        }
    }

    private var cover: some View {
        Group {
            if let img = spotify.artwork {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(Color.faint)
                }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06)))
    }

    private var idle: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                big(spotify.running ? "Rien ne joue sur Spotify." : "Spotify n'est pas ouvert.")
                sub(spotify.running ? "Lance un morceau, il s'affichera ici." : "Ouvre-le pour piloter ta musique d'ici.")
            }
            Spacer()
            if spotify.running {
                Button("Lecture") { spotify.playPause() }.buttonStyle(Pill(primary: true))
            } else {
                Button("Ouvrir Spotify") { spotify.open() }.buttonStyle(Pill(primary: true))
            }
        }
    }
}

/// Barre de lecture : avance toute seule, un clic déplace la lecture.
private struct MusicProgress: View {
    @ObservedObject var spotify: Spotify

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let d = max(1, spotify.track?.duration ?? 1), p = spotify.position(at: timeline.date)
            VStack(spacing: 2) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(Color.ink).frame(width: max(4, g.size.width * p / d))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { at in
                        spotify.seek(to: clamp(at.x / g.size.width, 0, 1) * d)
                    }
                }
                .frame(height: 12)
                HStack {
                    Text(time(p))
                    Spacer()
                    Text(time(d))
                }
                .font(Fonts.captionMono)
                .foregroundStyle(Color.faint)
            }
        }
    }

    private func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

private struct RoundControl: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { RoundBody(configuration: configuration, primary: primary) }
}

private struct RoundBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: primary ? 14 : 12.5, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(primary ? Color.onLight : Color.ink)
            .frame(width: primary ? 38 : 32, height: primary ? 38 : 32)
            .background(Circle().fill(primary ? Color.ink.opacity(hover ? 0.88 : 1)
                                              : .white.opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0.0001)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

private struct ApprovalPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#F5A524", 0.42)) {
            if let p = store.currentPermission {
                VStack(alignment: .leading, spacing: 9) {
                    Who(session: store.session(p.session), suffix: "Claude \(p.title)")
                    Text(p.detail)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
                    HStack(spacing: 8) {
                        Button("Refuser") { store.answer("deny") }.buttonStyle(Pill())
                        Button("Toujours autoriser") { store.answer("always") }.buttonStyle(Pill())
                        Button("Autoriser") { store.answer("allow") }.buttonStyle(Pill(primary: true))
                        if store.permissions.count > 1 {
                            Text("+\(store.permissions.count - 1) en attente").font(Fonts.caption).foregroundStyle(Color.muted)
                        }
                    }
                }
                .padding(.leading, 100)
                .padding(.trailing, 16)
            }
        }
    }
}

private struct FinishedPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.5)) {
            VStack(alignment: .leading, spacing: 8) {
                Who(session: store.focused, suffix: "Claude a terminé")
                big(store.focused?.history.last(where: { $0.hasPrefix("«") }).map { "C'est fait : \($0)" } ?? "C'est prêt.")
                HStack(spacing: 8) {
                    if let s = store.focused {
                        Button("Voir dans VS Code") { store.jump(to: s) }.buttonStyle(Pill(primary: true))
                    }
                    Button("OK") { store.dismissCurrent() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }
}

private struct ErrorPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#F4505E", 0.55)) {
            VStack(alignment: .leading, spacing: 8) {
                Who(session: store.focused, suffix: "Claude Code")
                big("Ça s'est arrêté.")
                sub(store.focused?.message ?? "", red: true)
                HStack(spacing: 8) {
                    if let s = store.focused {
                        Button("Voir dans VS Code") { store.jump(to: s) }.buttonStyle(Pill(primary: true))
                    }
                    Button("OK") { store.dismissCurrent() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }
}

/// Fichiers glissés vers l'encoche : à gauche on les garde (étagère), à droite on les convertit.
private struct UploadPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            DropZone(targeted: $store.dropKeep, color: "#3B9EFF", title: "Garder ici",
                     tags: ["Le temps de le coller ailleurs"], leading: 112) { store.keep($0) }
                .frame(width: 300)
            DropZone(targeted: $store.dropTargeted, color: "#34D399", title: "Convertir",
                     tags: ["WebP", "JPG", "PDF"], leading: 18) { store.dropped($0) }
        }
    }
}

private struct DropZone: View {
    @Binding var targeted: Bool
    let color: String
    let title: String
    let tags: [String]
    let leading: Double
    let onFiles: ([URL]) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.sunken)
                .overlay {
                    RadialGradient(colors: [Color(hex: color, targeted ? 0.6 : 0.22), .clear],
                                   center: UnitPoint(x: 0.5, y: 1.4), startRadius: 0, endRadius: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(targeted ? Color(hex: color, 0.6) : .white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 8) {
                big(title)
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) {
                        Text($0).font(.system(size: 11)).foregroundStyle(Color.soft).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.07)))
                    }
                }
            }
            .padding(.leading, leading)
            .padding(.trailing, 10)
        }
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let group = DispatchGroup()
            var urls = [URL?](repeating: nil, count: providers.count)
            let lock = NSLock()
            for (i, p) in providers.enumerated() {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    lock.lock(); urls[i] = url; lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { onFiles(urls.compactMap { $0 }) }
            return true
        }
    }
}

private struct ChoosePanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: .white.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 8) {
                let n = store.files.count
                big(n == 1 ? "\(store.files[0].lastPathComponent) est prêt." : "\(n) fichiers sont prêts.")
                sub("Tu veux en faire quoi ?")
                HStack(spacing: 8) {
                    Button("WebP") { store.convert("webp") }.buttonStyle(Pill(primary: true))
                    Button("JPG") { store.convert("jpg") }.buttonStyle(Pill())
                    Button("Fusionner en PDF") { store.convert("merge") }.buttonStyle(Pill())
                    if store.hasPDF { Button("Compresser") { store.convert("compress") }.buttonStyle(Pill()) }
                    Button("Annuler") { store.cancelFiles() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
        }
    }
}

private struct ConvertingPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.3)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Conversion de ").foregroundStyle(Color.soft) + Text(store.progressLabel).fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(store.progress * 100)) %").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.soft)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [Color(hex: "#1FA87A"), Color(hex: "#34D399")], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * store.progress))
                            .animation(.easeOut(duration: 0.3), value: store.progress)
                    }
                }
                .frame(height: 6)
                Button("Annuler") { store.cancelFiles() }.buttonStyle(Pill())
            }
            .padding(.leading, 90)
            .padding(.trailing, 24)
        }
    }
}

private struct ResultPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        Card(wash: Color(hex: store.resultOK ? "#34D399" : "#F4505E", 0.45)) {
            VStack(alignment: .leading, spacing: 9) {
                big(store.result)
                HStack(spacing: 8) {
                    if store.resultOK { Button("Afficher dans le Finder") { store.revealResult() }.buttonStyle(Pill(primary: true)) }
                    Button("OK") { store.collapse() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }
}

/// Compteur d'images par seconde (diagnostic) : ENCOCHE_FPS=1 l'affiche dans la console.
enum FPS {
    private static let enabled = ProcessInfo.processInfo.environment["ENCOCHE_FPS"] != nil
    private static var count = 0
    private static var since = CACurrentMediaTime()
    private static var worst = 0.0
    private static var last = CACurrentMediaTime()

    static func tick() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        worst = max(worst, now - last)
        last = now
        count += 1
        if now - since >= 1 {
            print(String(format: "fps %d · pire image %.0f ms", count, worst * 1000))
            fflush(stdout)
            count = 0; since = now; worst = 0
        }
    }
}
