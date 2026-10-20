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
        let radius = store.mode == .expanded ? 30.0 : store.mode == .peek ? 20.0 : store.mode == .compact ? 14.0 : 10.0
        ZStack(alignment: .top) {
            IslandShape(flare: flare, radius: radius)
                .fill(Color.black)
                .frame(width: size.width + 2 * flare, height: size.height)
            ZStack(alignment: .topLeading) {
                // Le contenu n'existe que dans l'encoche ouverte : caché mais présent, il continuait
                // de s'animer (points qui pulsent) et coûtait du CPU en permanence.
                if store.mode == .peek, let t = store.toast {
                    PeekView(store: store, toast: t)
                        .frame(width: size.width, height: size.height, alignment: .bottom)
                        .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.08)))
                }
                if store.mode == .expanded {
                    IslandContent(store: store)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                                                removal: .opacity.animation(.easeIn(duration: 0.1))))
                }
                // Un seul minuteur pour tous les personnages : 60 images/s ouverte, 20 en compact
                // (le bonhomme y fait 17 points : plus d'images ne se voient pas, mais se paient en CPU).
                TimelineView(.animation(minimumInterval: store.mode == .expanded ? nil : 1.0 / 20,
                                        paused: store.mode == .hidden && store.mochiSlot.hb < 0.5)) { timeline in
                    ZStack(alignment: .topLeading) {
                        MinisView(store: store, frame: timeline.date)
                            .frame(width: 52, height: store.notch.height)
                            .position(x: size.width - 26, y: store.notch.height / 2)
                            .opacity(store.mode == .compact || store.mode == .peek ? 1 : 0)
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
            guard store.mode == .compact || store.mode == .peek else { return }
            // Claude suit un plan : son avancement (anneau + « 3/7 ») remplace les mini-bonshommes.
            if let p = store.activePlan {
                let c = CGPoint(x: 15, y: size.height / 2), r = 6.5
                ctx.stroke(Path(ellipseIn: CGRect(cx: c.x, cy: c.y, w: 2 * r, h: 2 * r)), with: .color(.white.opacity(0.16)), lineWidth: 2.2)
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .degrees(-90),
                           endAngle: .degrees(-90 + 360 * Double(p.done) / Double(max(1, p.total))), clockwise: false)
                ctx.stroke(arc, with: .color(.success), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                ctx.draw(Text("\(p.done)/\(p.total)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(Color.soft), at: CGPoint(x: 36, y: size.height / 2))
                return
            }
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
        Button(Care.shared.enabled ? "Couper les rappels (pause, eau, nuit)" : "Activer les rappels (pause, eau, nuit)") {
            Care.shared.enabled.toggle()
            store.objectWillChange.send()
        }
        Text("⌥Espace : écrire à Claude · ⌥⇧Espace : lui dicter")
        Divider()
        Menu("Skin") {
            ForEach(Skin.all) { s in
                Button { store.setSkin(s) } label: {
                    if s.id == store.mochi.skin.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
        }
        Menu("Couleur") {
            Button { store.setColor(nil) } label: {
                if store.mochi.tint == nil { Label("Celle du skin", systemImage: "checkmark") } else { Text("Celle du skin") }
            }
            Divider()
            ForEach(Skin.colors, id: \.hex) { c in
                Button { store.setColor(c.hex) } label: {
                    if store.mochi.tint == c.hex { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
        }
        Button("Réglages…") { SettingsWindow.show() }
        Button("Quitter Encoche") { NSApp.terminate(nil) }
    }
}

// MARK: - Bulles (peek)

/// Pastille ronde : une icône, ou l'initiale de la personne, sur sa couleur.
struct Avatar: View {
    let name: String
    let color: String
    var icon: String? = nil
    var size = 22.0

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: color))
            if let icon {
                Image(systemName: icon).font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(.white)
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// L'encoche fermée qui s'élargit : « Léo : on se fait une pause ? ». Clic ou survol : on ouvre.
private struct PeekView: View {
    @ObservedObject var store: Store
    let toast: Toast

    var body: some View {
        Button { store.openToast() } label: {
            HStack(spacing: 9) {
                Avatar(name: toast.title, color: toast.color, icon: toast.icon, size: 22)
                (Text(toast.title).fontWeight(.semibold) + Text("  ") + Text(toast.text).foregroundColor(Color.soft))
                    .font(Fonts.label)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.faint)
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("\(toast.title) \(toast.text). Ouvrir")
    }
}

/// La même bulle quand l'encoche est déjà ouverte sur autre chose : elle flotte en bas.
private struct ToastPill: View {
    @ObservedObject var store: Store
    let toast: Toast

    var body: some View {
        Button { store.openToast() } label: {
            HStack(spacing: 8) {
                Avatar(name: toast.title, color: toast.color, icon: toast.icon, size: 20)
                (Text(toast.title).fontWeight(.semibold) + Text("  ") + Text(toast.text).foregroundColor(Color.soft))
                    .font(Fonts.label)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Capsule().fill(Color(hex: "#24262C")))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(HoverDim())
        .accessibilityLabel("\(toast.title) \(toast.text). Ouvrir")
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
                case .dev: DevPanel(store: store)
                case .care: CarePanel(store: store)
                case .todos: TodosPanel(store: store)
                case .friends: FriendsPanel(store: store)
                }
            }
            .id(store.view)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(.easeOut(duration: 0.26).delay(0.1)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
            .padding(.top, store.cardTop)
            .padding([.horizontal, .bottom], 10)
        }
        .frame(width: Store.expandedWidth, height: store.viewHeight, alignment: .top)
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                ToastPill(store: store, toast: t)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: store.toast)
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
            Button { SettingsWindow.show() } label: { Image(systemName: "gearshape.fill").font(.system(size: 11.5, weight: .semibold)) }
                .buttonStyle(IconButton())
                .help("Réglages")
                .accessibilityLabel("Réglages")
            Button { store.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(IconButton())
                .help("Fermer l'encoche")
                .accessibilityLabel("Fermer l'encoche")
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
    @ObservedObject var friends = Friends.shared
    @Namespace private var ns

    private enum Tab { case claude, music, shelf, dev, friends }

    private var current: Tab {
        switch store.view {
        case .music: .music
        case .shelf: .shelf
        case .dev: .dev
        case .friends: .friends
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
            item(.dev, icon: "terminal", title: "Dev", badge: nil, live: false) { store.goTo(.dev) }
            // Messages non lus d'abord (bulle), sinon le nombre de potes sur leur Mac.
            let online = friends.list.filter { $0.online && $0.presence == .active }.count
            item(.friends, icon: friends.unread > 0 ? "bubble.left.and.bubble.right.fill" : "person.2.fill", title: "Potes",
                 badge: friends.unread > 0 ? "\(friends.unread)" : online > 0 ? "\(online)" : nil, live: false) {
                if friends.unread > 0 { store.friendsShowsChat = true }
                store.goTo(.friends)
            }
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
            .padding(.horizontal, active ? 9 : 6)
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
            if !suffix.isEmpty { Text(suffix).foregroundStyle(Color.muted) }
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
                        Who(session: store.focused, suffix: "")
                        ModelMenu(store: store)
                        Spacer(minLength: 4)
                        if let s = store.focused {
                            Button { store.jump(to: s) } label: {
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(IconButton())
                            .help("Ouvrir dans \(s.place)")
                            .accessibilityLabel("Ouvrir \(s.name) dans \(s.place)")
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
                            // Avec un plan, la ligne du haut devient son avancement (clic : la liste complète).
                            let plan = store.focused?.plan
                            if let plan { PlanLine(store: store, done: plan.done, total: plan.total) }
                            let lines = Array((store.focused?.history ?? []).suffix(plan == nil ? 2 : 1))
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
                    FavoritesRow(store: store)
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

/// Le modèle de la session choisie, en pastille ; un clic propose les autres.
private struct ModelMenu: View {
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        let current = store.focused?.model ?? ""
        let shown = current.isEmpty ? store.defaultModel : current
        let vscode = store.focused?.entrypoint == "claude-vscode"
        Menu {
            // Terminal : `/model nom` change la session. VS Code : son choix de modèle est une action de
            // son interface, on ouvre donc la session pour le faire là-bas.
            if let s = store.focused, !vscode {
                Section("Cette session (\(s.name))") {
                    ForEach(ClaudeModel.all) { m in
                        Button { store.setModel(m) } label: { check(m.name, m.arg == current) }
                    }
                }
            }
            Section("Nouvelles sessions") {
                ForEach(ClaudeModel.all) { m in
                    Button { store.setDefaultModel(m) } label: { check(m.name, isDefault(m)) }
                }
            }
            if let s = store.focused, vscode {
                Divider()
                Button("Changer celle-ci dans VS Code (/model)…") { store.jump(to: s) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(shown.isEmpty ? "Modèle" : ClaudeModel.label(shown)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Fonts.caption.weight(.medium))
            .foregroundStyle(hover ? Color.ink : Color.soft)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(hover ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.focused == nil || store.sending)
        .onHover { hover = $0 }
        .help("Modèle de Claude : cette session, ou les nouvelles")
        .accessibilityLabel("Modèle : \(shown.isEmpty ? "inconnu" : ClaudeModel.label(shown))")
    }

    @ViewBuilder private func check(_ name: String, _ on: Bool) -> some View {
        if on { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    /// Le réglage peut être un nom court (« opus ») ou complet (« claude-opus-5-5 »).
    private func isDefault(_ m: ClaudeModel) -> Bool {
        let d = store.defaultModel.lowercased()
        return !d.isEmpty && (m.arg == d || m.arg.contains("-\(d)-"))
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

/// Prompts favoris : un clic les envoie ; « + » garde le message en cours ; clic droit pour retirer.
private struct FavoritesRow: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(store.favorites, id: \.self) { text in
                    Button(text) { store.sendFavorite(text) }
                        .buttonStyle(Chip())
                        .disabled(store.sending || store.focused == nil)
                        .help("Envoyer « \(text) » à Claude")
                        .contextMenu { Button("Retirer des favoris") { store.removeFavorite(text) } }
                }
                Button { store.addFavorite() } label: { Image(systemName: "plus").font(.system(size: 9.5, weight: .bold)) }
                    .buttonStyle(Chip())
                    .help("Garder le message en cours comme favori")
                    .accessibilityLabel("Ajouter le message aux favoris")
            }
        }
        .frame(height: 22)
    }
}

/// Petite pastille de texte (favoris, fichiers modifiés).
private struct Chip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }
}

private struct ChipBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(Fonts.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(hover ? Color.ink : Color.soft)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.18 : hover ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.05)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Bouton-icône du champ d'écriture (capture, micro).
private struct MiniIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MiniIconBody(configuration: configuration) }
}

private struct MiniIconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(hover ? Color.ink : Color.muted)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : hover ? 0.1 : 0)))
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}

/// Champ « Écris à Claude… » et bouton d'envoi, en bas de la section de gauche.
private struct ComposeBar: View {
    @ObservedObject var store: Store
    @ObservedObject var voice = Voice.shared
    var body: some View {
        let empty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 6) {
            ComposeField(text: $store.draft,
                         placeholder: voice.listening ? "Je t'écoute…"
                             : store.focused.map { "Écris à Claude (\($0.name))…" } ?? "Écris à Claude…",
                         onSubmit: { store.submitDraft() },
                         onEditing: { store.setComposing($0) },
                         focus: store.wantsFocus,
                         onFocused: { store.wantsFocus = false })
                .frame(height: 18)
            Button { store.capture() } label: { Image(systemName: "viewfinder").font(.system(size: 11.5, weight: .semibold)) }
                .buttonStyle(MiniIcon())
                .help("Capturer une zone de l'écran et la montrer à Claude")
                .accessibilityLabel("Capture d'écran pour Claude")
            Button { store.toggleDictation() } label: {
                Image(systemName: voice.listening ? "waveform" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: voice.listening)
                    .foregroundStyle(voice.listening ? Color.danger : Color.muted)
            }
            .buttonStyle(MiniIcon())
            .help(voice.listening ? "Arrêter la dictée" : "Dicter le message (⌥⇧Espace)")
            .accessibilityLabel(voice.listening ? "Arrêter la dictée" : "Dicter le message")
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
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(voice.listening ? Color.danger.opacity(0.5) : .white.opacity(store.composing ? 0.16 : 0.04)))
        .animation(.easeOut(duration: 0.15), value: store.composing)
    }
}

/// Étagère : les fichiers gardés (glisser = déposer ailleurs, clic = copier) ou l'historique
/// du presse-papiers (clic = recopier).
private struct ShelfPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var clipboard = ClipHistory.shared

    var body: some View {
        let clips = store.shelfShowsClips
        Card(wash: Color(hex: "#3B9EFF", 0.22)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Segments(left: "Fichiers \(store.shelf.count)", right: "Copies \(clipboard.clips.count)", rightOn: clips) {
                        store.shelfShowsClips = $0
                        Sound.shared.play("tick")
                    }
                    if let notice = store.notice {
                        Text(notice.text).font(Fonts.label.weight(.medium))
                            .foregroundStyle(notice.ok ? Color.success : Color.danger).lineLimit(1)
                    } else {
                        Text(clips ? (clipboard.clips.isEmpty ? "Ce que tu copies s'affiche ici." : "Clique pour recopier.")
                                   : (store.shelf.isEmpty ? "Glisse un fichier sur l'encoche." : "Glisse ou clique pour copier."))
                            .font(Fonts.label).foregroundStyle(Color.muted).lineLimit(1)
                    }
                    Spacer()
                    if !clips {
                        Button { store.capture() } label: { Image(systemName: "viewfinder").font(.system(size: 11.5, weight: .semibold)) }
                            .buttonStyle(IconButton())
                            .help("Capturer une zone de l'écran")
                            .accessibilityLabel("Capture d'écran")
                    }
                    if clips ? !clipboard.clips.isEmpty : !store.shelf.isEmpty {
                        Button("Vider") { clips ? clipboard.clear() : store.clearShelf() }.buttonStyle(Pill())
                    }
                }
                if clips {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(clipboard.clips) { c in ClipItem(store: store, clip: c) }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        // Les plus récents d'abord ; au-delà de 6, on l'indique.
                        ForEach(store.shelf.suffix(6).reversed(), id: \.self) { url in ShelfItem(store: store, url: url) }
                        if store.shelf.count > 6 {
                            Text("+\(store.shelf.count - 6)").font(Fonts.labelBold)
                                .foregroundStyle(Color.muted).padding(.leading, 4)
                        }
                    }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
    }
}

/// Deux choix côte à côte, la pastille claire sur celui qui est actif.
private struct Segments: View {
    let left: String
    let right: String
    let rightOn: Bool
    let pick: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { isRight in
                let on = isRight == rightOn
                Button { if !on { pick(isRight) } } label: {
                    Text(isRight ? right : left)
                        .font(Fonts.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(on ? Color.ink : Color.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(.white.opacity(on ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
        .animation(.easeOut(duration: 0.15), value: rightOn)
    }
}

/// Un élément copié : texte (3 lignes) ou image. Clic = recopier ; glisser = déposer ailleurs.
private struct ClipItem: View {
    @ObservedObject var store: Store
    let clip: ClipHistory.Clip
    @State private var hover = false

    var body: some View {
        Group {
            if let img = clip.image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 66).clipped()
            } else {
                Text(clip.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.soft)
                    .lineLimit(4)
                    .frame(width: 108, height: 58, alignment: .topLeading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.04)))
        .clipShape(RoundedRectangle(cornerRadius: Radius.item, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(hover ? 0.12 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            ClipHistory.shared.copy(clip)
            Sound.shared.play("pop")
            store.say("Copié ✓ colle-le où tu veux (⌘V)", ok: true)
        }
        .onDrag {
            store.startDragOut()
            if let t = clip.text { return NSItemProvider(object: t as NSString) }
            if let png = clip.png { return NSItemProvider(item: png as NSData, typeIdentifier: "public.png") }
            return NSItemProvider()
        }
        .contextMenu {
            Button("Copier") { ClipHistory.shared.copy(clip) }
            Button("Retirer") { ClipHistory.shared.remove(clip) }
            Divider()
            Button("Tout effacer") { ClipHistory.shared.clear() }
        }
        .help(clip.text.map { String($0.prefix(400)) } ?? "Image copiée")
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

/// Onglet Dev : serveurs locaux à gauche, santé du Mac à droite.
/// Onglet Dev : le mini-terminal, ou les serveurs locaux et la santé du Mac.
private struct DevPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        if store.devShowsServers { ServersPanel(store: store) } else { TerminalPanel(store: store) }
    }
}

private struct DevSwitch: View {
    @ObservedObject var store: Store
    var body: some View {
        Segments(left: "Terminal", right: "Serveurs · Mac", rightOn: store.devShowsServers) { on in
            Sound.shared.play("tick")
            withAnimation(Store.openAnimation) { store.devShowsServers = on }
        }
    }
}

/// Mini-terminal : dossier, résultat en direct, commande (Entrée), ↑/↓ pour l'historique.
private struct TerminalPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var shell = Shell.shared

    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.12)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    DevSwitch(store: store)
                    folderMenu
                    Spacer(minLength: 4)
                    if shell.running {
                        ProgressView().controlSize(.mini)
                    } else if let code = shell.lastExit {
                        Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(code == 0 ? Color.success : Color.danger)
                            .help(code == 0 ? "Réussi" : "Code de sortie \(code)")
                    }
                    Button { shell.clear() } label: { Image(systemName: "trash").font(.system(size: 10.5, weight: .semibold)) }
                        .buttonStyle(MiniIcon()).help("Effacer").accessibilityLabel("Effacer le résultat")
                    Button { shell.openInTerminal() } label: { Image(systemName: "macwindow").font(.system(size: 10.5, weight: .semibold)) }
                        .buttonStyle(MiniIcon()).help("Ouvrir ce dossier dans le Terminal").accessibilityLabel("Ouvrir dans le Terminal")
                }
                ScrollViewReader { reader in
                    ScrollView(.vertical) {
                        Text(shell.output.isEmpty ? "Tape une commande (git status, npm run build…) : le résultat s'affiche ici."
                                                  : shell.output.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(shell.output.isEmpty ? Color.faint : Color.soft)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .onChange(of: shell.output.count) { _, _ in reader.scrollTo("fin", anchor: .bottom) }
                    .onAppear { reader.scrollTo("fin", anchor: .bottom) }
                }
                .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(Color.sunken))
                .overlay(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).strokeBorder(.white.opacity(0.05)))
                HStack(spacing: 6) {
                    Text("$").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Color.success)
                    ComposeField(text: $shell.command, placeholder: "Commande dans \(shell.folderName)… (Entrée)",
                                 onSubmit: { shell.run() }, onEditing: { store.setComposing($0) }, onArrow: { shell.browse($0) })
                        .frame(height: 18)
                    if shell.running {
                        Button { shell.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold)) }
                            .buttonStyle(MiniIcon()).help("Arrêter (comme ⌃C)").accessibilityLabel("Arrêter la commande")
                    } else {
                        Button { shell.run() } label: { Image(systemName: "return").font(.system(size: 10.5, weight: .bold)) }
                            .buttonStyle(MiniIcon()).help("Lancer (Entrée)").accessibilityLabel("Lancer la commande")
                            .disabled(shell.command.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(store.composing ? 0.11 : 0.07)))
            }
            .padding(.leading, 100)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
    }

    /// Le dossier : projets des sessions Claude, dossiers récents, ou au choix.
    private var folderMenu: some View {
        Menu {
            let projects = Array(Set(store.sessions.map(\.cwd))).sorted()
            if !projects.isEmpty {
                Section("Projets Claude") {
                    ForEach(projects, id: \.self) { p in Button(URL(fileURLWithPath: p).lastPathComponent) { shell.setFolder(URL(fileURLWithPath: p)) } }
                }
            }
            let recent = shell.recent.filter { !projects.contains($0) }
            if !recent.isEmpty {
                Section("Récents") {
                    ForEach(recent, id: \.self) { p in Button(URL(fileURLWithPath: p).lastPathComponent) { shell.setFolder(URL(fileURLWithPath: p)) } }
                }
            }
            Divider()
            Button("Dossier personnel") { shell.setFolder(FileManager.default.homeDirectoryForCurrentUser) }
            Button("Choisir un dossier…") { shell.chooseFolder() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 10))
                Text(shell.folderName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Fonts.caption.weight(.medium))
            .foregroundStyle(Color.soft)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(shell.folder.path)
    }
}

private struct ServersPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var dev = DevMonitor.shared

    var body: some View {
        HStack(spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    DevSwitch(store: store)
                    if dev.servers.isEmpty {
                        Spacer(minLength: 0)
                        Text(dev.scanned ? "Aucun serveur ne tourne." : "Je regarde…").font(Fonts.lead)
                        Text("Lance npm run dev (ou autre) : il apparaîtra ici.").font(Fonts.label).foregroundStyle(Color.muted)
                        Spacer(minLength: 0)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 4) {
                                ForEach(dev.servers) { s in ServerRow(server: s) }
                            }
                        }
                    }
                }
                .padding(.leading, 100)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
            }
            .frame(width: 400)
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    Gauge(label: "CPU", value: dev.health.cpu)
                    Gauge(label: "Mémoire", value: dev.health.memory)
                    if let b = dev.health.battery {
                        Gauge(label: dev.health.charging ? "Batterie ⚡︎" : "Batterie", value: Double(b) / 100, invert: true)
                    }
                    HStack {
                        Text("Chaleur").foregroundStyle(Color.muted)
                        Spacer()
                        Text(thermal.0).foregroundStyle(thermal.1)
                    }
                    .font(Fonts.caption)
                }
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .onAppear { dev.watch(true) }
        .onDisappear { dev.watch(false) }
    }

    private var thermal: (String, Color) {
        switch dev.health.thermal {
        case .nominal: ("Normale", .success)
        case .fair: ("Tiède", .warning)
        case .serious: ("Chaud", .danger)
        case .critical: ("Brûlant", .danger)
        @unknown default: ("—", .muted)
        }
    }
}

private struct ServerRow: View {
    let server: DevMonitor.Server
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.success).frame(width: 6, height: 6)
            Text(":\(server.port)").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            Text(server.project.isEmpty ? server.command : "\(server.project) · \(server.command)")
                .font(Fonts.caption).foregroundStyle(Color.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button { DevMonitor.shared.open(server) } label: { Image(systemName: "safari").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(MiniIcon())
                .help("Ouvrir http://localhost:\(server.port)")
                .accessibilityLabel("Ouvrir le port \(server.port) dans le navigateur")
            Button { DevMonitor.shared.stop(server) } label: { Image(systemName: "stop.fill").font(.system(size: 9.5, weight: .bold)) }
                .buttonStyle(MiniIcon())
                .help("Arrêter ce serveur (\(server.command), pid \(server.pid))")
                .accessibilityLabel("Arrêter le serveur du port \(server.port)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0.04)))
        .onHover { hover = $0 }
    }
}

/// Jauge de la santé du Mac : vert, puis orange et rouge quand ça monte (ou descend, pour la batterie).
private struct Gauge: View {
    let label: String
    let value: Double?
    var invert = false

    var body: some View {
        let v = value ?? 0, load = invert ? 1 - v : v
        let tint: Color = load > 0.85 ? .danger : load > 0.65 ? .warning : .success
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(Color.muted)
                Spacer()
                Text(value.map { "\(Int(($0 * 100).rounded())) %" } ?? "—").monospacedDigit()
            }
            .font(Fonts.caption)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(3, g.size.width * v))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.4), value: v)
        }
    }
}

/// Rappel du bonhomme : pause, eau, nuit, batterie, chaleur.
private struct CarePanel: View {
    @ObservedObject var store: Store

    var body: some View {
        let r = store.reminder ?? .pause
        Card(wash: Color(hex: tint(r), 0.4)) {
            VStack(alignment: .leading, spacing: 8) {
                big(title(r))
                sub(detail(r))
                HStack(spacing: 8) {
                    switch r {
                    case .pause:
                        Button("C'est fait") { store.answerReminder(later: false) }.buttonStyle(Pill(primary: true))
                        Button("Dans 10 min") { store.answerReminder(later: true) }.buttonStyle(Pill())
                    case .heat:
                        Button("Voir l'onglet Dev") { store.goTo(.dev) }.buttonStyle(Pill(primary: true))
                        Button("OK") { store.answerReminder(later: false) }.buttonStyle(Pill())
                    default:
                        Button(r == .water ? "C'est fait" : "OK") { store.answerReminder(later: false) }.buttonStyle(Pill(primary: true))
                    }
                    Spacer()
                    Button("Couper les rappels") {
                        Care.shared.enabled = false
                        store.collapse()
                    }
                    .buttonStyle(.plain)
                    .font(Fonts.caption)
                    .foregroundStyle(Color.faint)
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }

    private func title(_ r: Reminder) -> String {
        switch r {
        case .pause: "Ça fait 50 min que tu codes."
        case .water: "Un verre d'eau ?"
        case .night(let h): "Il est \(h) h du matin."
        case .battery(let b): "Batterie à \(b) %."
        case .heat: "Ton Mac chauffe."
        }
    }

    private func detail(_ r: Reminder) -> String {
        switch r {
        case .pause: "Lève-toi, étire-toi, regarde au loin 20 secondes."
        case .water: "Ton cerveau code mieux hydraté."
        case .night: "Claude peut continuer demain. Toi, tu devrais dormir."
        case .battery: "Branche ton Mac avant qu'il coupe en plein build."
        case .heat: "Un build ou un serveur tourne fort ? Jette un œil."
        }
    }

    private func tint(_ r: Reminder) -> String {
        switch r {
        case .pause: "#A78BFA"
        case .water: "#38BDF8"
        case .night: "#6366F1"
        case .battery, .heat: "#F4505E"
        }
    }
}

/// « ▰▰▰▱▱ 3/7 · Écrit les tests » : l'avancement du plan de Claude, clic pour la liste.
private struct PlanLine: View {
    @ObservedObject var store: Store
    let done: Int
    let total: Int

    var body: some View {
        Button { store.goTo(.todos) } label: {
            HStack(spacing: 7) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(Color.success).frame(width: max(3, g.size.width * Double(done) / Double(max(1, total))))
                    }
                }
                .frame(width: 34, height: 4)
                Text("\(done)/\(total)").font(Fonts.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Color.soft)
                Text(store.focused?.currentTodo?.activeForm ?? (done == total ? "Plan terminé" : "Plan de Claude"))
                    .font(Fonts.label).foregroundStyle(Color.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverDim())
        .help("Voir la liste des tâches de Claude")
    }
}

/// Le plan de Claude : ses tâches, cochées au fur et à mesure.
private struct TodosPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        Card(wash: Color(hex: "#34D399", 0.22)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Who(session: store.focused, suffix: "plan de Claude")
                    Spacer()
                    if let p = store.focused?.plan {
                        Text("\(p.done)/\(p.total)").font(Fonts.labelBold).monospacedDigit().foregroundStyle(Color.soft)
                    }
                }
                if let todos = store.focused?.todos, !todos.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(todos.enumerated()), id: \.offset) { _, t in TodoRow(todo: t) }
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    Text("Pas de plan pour l'instant.").font(Fonts.lead)
                    Text("Quand Claude découpe une demande en étapes, elles s'affichent ici.").font(Fonts.label).foregroundStyle(Color.muted)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct TodoRow: View {
    let todo: Todo

    var body: some View {
        let done = todo.status == "completed", now = todo.status == "in_progress"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success) }
                else if now { PulseDot(color: .success).frame(width: 12) }
                else { Image(systemName: "circle").foregroundStyle(Color.faint) }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14)
            Text(now && !todo.activeForm.isEmpty ? todo.activeForm : todo.content)
                .font(now ? Fonts.lead : Fonts.label)
                .foregroundStyle(done ? Color.faint : now ? Color.ink : Color.soft)
                .strikethrough(done, color: Color.faint)
                .lineLimit(1)
        }
    }
}

/// Entre potes : les bonshommes du groupe (humeur, présence ; un clic envoie un cœur), ou le chat.
private struct FriendsPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var friends = Friends.shared

    var body: some View {
        Card(wash: Color(hex: "#F472B6", 0.24)) {
            Group {
                if !friends.configured && friends.hasChat {
                    ChatView(store: store)  // seulement des conversations privées
                } else if !friends.configured {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            big("Joue avec tes potes.")
                            sub("Crée un groupe, donne-leur le code : vous verrez vos bonshommes ici, et vous pourrez discuter.")
                        }
                        Spacer()
                        Button("Configurer") { SettingsWindow.show() }.buttonStyle(Pill(primary: true))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Segments(left: "Potes", right: friends.unread > 0 ? "Chat \(friends.unread)" : "Chat", rightOn: store.friendsShowsChat) { on in
                                Sound.shared.play("tick")
                                withAnimation(Store.openAnimation) { store.friendsShowsChat = on }
                            }
                            if let n = friends.notice {
                                Text(n).font(Fonts.label.weight(.medium)).foregroundStyle(Color(hex: "#FF9ECF")).lineLimit(1)
                            } else if !store.friendsShowsChat {
                                Text(friends.list.isEmpty ? "Donne le code du groupe à tes potes." : "Clic : un cœur · survol : coucou")
                                    .font(Fonts.label).foregroundStyle(Color.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .animation(.easeOut(duration: 0.2), value: friends.notice)
                        if store.friendsShowsChat {
                            ChatView(store: store)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(friends.list) { f in FriendTile(friend: f) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 14)
            .padding(.vertical, 11)
        }
    }
}

/// Chat du groupe : messages regroupés par personne, l'heure aux pauses, l'état de mes messages,
/// des réponses rapides quand c'est vide, et le champ (Entrée envoie).
private struct ChatView: View {
    @ObservedObject var store: Store
    @ObservedObject var friends = Friends.shared

    private static let quick = ["Salut 👋", "Qui code en ce moment ?", "Pause café ?", "Je lance un build 🚀"]
    private static let quickPrivate = ["Coucou ❤️", "Tu fais quoi ?", "Je finis et j'arrive", "Bonne nuit 🌙"]

    private var isGroup: Bool { friends.conversations.first { $0.id == friends.currentConv }?.isGroup ?? true }

    var body: some View {
        let list = friends.messages(friends.currentConv)
        return VStack(spacing: 6) {
            if friends.conversations.count > 1 { conversations }
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if list.isEmpty { empty }
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                            let prev = i > 0 ? list[i - 1] : nil
                            let pause = prev.map { m.at.timeIntervalSince($0.at) > 10 * 60 } ?? true
                            if pause { TimeSeparator(date: m.at) }
                            ChatRow(message: m, color: color(m), first: pause || prev?.from != m.from)
                        }
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding(.horizontal, 2)
                }
                .onAppear { reader.scrollTo("fin", anchor: .bottom); friends.markRead() }
                .onChange(of: list.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("fin", anchor: .bottom) }
                    friends.markRead()
                }
                .onChange(of: friends.currentConv) { _, _ in reader.scrollTo("fin", anchor: .bottom) }
            }
            input
        }
    }

    /// Les conversations : le groupe, et chaque conversation privée (avec ses non-lus).
    private var conversations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(friends.conversations) { c in
                    let on = c.id == friends.currentConv, unread = friends.unreadBy[c.id] ?? 0
                    Button { Sound.shared.play("tick"); friends.select(c.id) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: c.isGroup ? "person.3.fill" : "lock.fill").font(.system(size: 8.5, weight: .bold))
                            Text(c.name).font(Fonts.caption.weight(.semibold))
                            if unread > 0 {
                                Text("\(unread)").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(Color.onLight)
                                    .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                                    .background(Capsule().fill(Color(hex: "#FF8BC4")))
                            }
                        }
                        .foregroundStyle(on ? Color.ink : Color.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(.white.opacity(on ? 0.14 : 0.05)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(c.isGroup ? "Le chat du groupe de potes" : "Conversation privée avec \(c.name)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .frame(height: 22)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("Pas encore de message. Lance la conversation :").font(Fonts.label).foregroundStyle(Color.muted)
            HStack(spacing: 5) {
                ForEach(isGroup ? Self.quick : Self.quickPrivate, id: \.self) { q in Button(q) { friends.sendChat(q) }.buttonStyle(Chip()) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var input: some View {
        let count = friends.draft.count, empty = friends.draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            ComposeField(text: $friends.draft, placeholder: placeholder,
                         onSubmit: { friends.sendChat() }, onEditing: { store.setComposing($0) })
                .frame(height: 18)
            if count > Friends.chatLimit - 100 {  // on approche de la limite
                Text("\(Friends.chatLimit - count)").font(Fonts.caption).monospacedDigit()
                    .foregroundStyle(count > Friends.chatLimit ? Color.danger : Color.faint)
            }
            Button { friends.sendChat() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.onLight)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(hex: "#FF8BC4")))
            }
            .buttonStyle(.plain)
            .opacity(empty ? 0.35 : 1)
            .disabled(empty)
            .help("Envoyer (Entrée)")
            .accessibilityLabel("Envoyer le message")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(store.composing ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(.white.opacity(store.composing ? 0.16 : 0.04)))
    }

    private var placeholder: String {
        guard let c = friends.conversations.first(where: { $0.id == friends.currentConv }), !c.isGroup else { return "Écris à tes potes…" }
        return "Écris à \(c.name)…"
    }

    private func color(_ m: Friends.Message) -> String {
        if m.from.hasPrefix("phone:") { return Friends.phoneColor }
        let f = friends.list.first { $0.id == m.from }
        return f?.mochi.tint ?? f?.mochi.skin.aura ?? "#FF8BC4"
    }
}

/// « Aujourd'hui 14:32 », « Hier 22:10 », « 18 oct. 09:05 » : quand la conversation a fait une pause.
private struct TimeSeparator: View {
    let date: Date
    var body: some View {
        Text(label).font(Fonts.caption.weight(.medium)).foregroundStyle(Color.faint)
            .frame(maxWidth: .infinity).padding(.vertical, 5)
    }
    private var label: String {
        let cal = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Aujourd'hui \(time)" }
        if cal.isDateInYesterday(date) { return "Hier \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

/// Une bulle. Pour un pote : sa pastille et son nom au premier message d'une série. Pour moi : l'état.
private struct ChatRow: View {
    let message: Friends.Message
    let color: String
    let first: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.mine {
                Spacer(minLength: 70)
            } else {
                Group {
                    if first { Avatar(name: message.name, color: color, size: 20) } else { Color.clear.frame(width: 20, height: 1) }
                }
                .padding(.bottom, 1)
            }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                if first && !message.mine {
                    HStack(spacing: 3) {
                        Text(message.name).font(Fonts.caption.weight(.semibold))
                        if message.from.hasPrefix("phone:") {
                            Image(systemName: "iphone").font(.system(size: 9, weight: .semibold)).help("Depuis son téléphone")
                        }
                    }
                    .foregroundStyle(Color(hex: color))
                }
                Text(message.text)
                    .font(Fonts.label)
                    .foregroundStyle(message.mine ? Color.onLight : Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(message.mine ? Color(hex: "#FF8BC4") : .white.opacity(0.09)))
                    .opacity(message.state == "sending" ? 0.6 : 1)
                if message.mine, let state = message.state, state != "sent" { status(state) }
            }
            .help(message.at.formatted(date: .abbreviated, time: .shortened))
            if !message.mine { Spacer(minLength: 70) }
        }
        .padding(.top, first ? 5 : 0)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder private func status(_ state: String) -> some View {
        if state == "failed" {
            Button { Friends.shared.retry(message) } label: {
                Label("Non envoyé · Réessayer", systemImage: "exclamationmark.circle.fill")
                    .font(Fonts.caption.weight(.medium)).foregroundStyle(Color.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message non envoyé, réessayer")
        } else {
            Text("Envoi…").font(Fonts.caption).foregroundStyle(Color.faint)
        }
    }
}

private struct FriendTile: View {
    let friend: Friends.Friend
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                Canvas { ctx, size in
                    _ = tl.date
                    friend.mochi.update(CACurrentMediaTime())
                    friend.mochi.draw(ctx, cx: size.width / 2, cy: size.height / 2 + 4, hb: 28)
                }
            }
            .frame(width: 84, height: 56)
            .opacity(friend.online ? (friend.presence == .away ? 0.7 : 1) : 0.4)
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(friend.name).font(Fonts.labelBold).lineLimit(1)
            }
            Text(status)
                .font(Fonts.caption)
                .foregroundStyle(friend.online && friend.presence == .active ? Color(hex: STYLES[friend.state]?.col ?? "#9A9FA8") : Color.faint)
                .lineLimit(1)
        }
        .frame(width: 96)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(.white.opacity(hover ? 0.09 : 0.03)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { Friends.shared.poke(friend, "wave") } label: { Image(systemName: "hand.wave.fill").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(MiniIcon())
                    .help("Faire coucou à \(friend.name)")
                    .accessibilityLabel("Faire coucou à \(friend.name)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Friends.shared.poke(friend, "heart") }
        .contextMenu {
            Button("Envoyer un cœur") { Friends.shared.poke(friend, "heart") }
            Button("Faire coucou") { Friends.shared.poke(friend, "wave") }
        }
        .help("Envoyer un cœur à \(friend.name)")
        .accessibilityLabel("\(friend.name), \(status)")
    }

    /// Vert : sur son Mac. Orange : absent. Gris : hors ligne.
    private var dot: Color {
        !friend.online ? Color.faint : friend.presence == .active ? Color.success : Color.warning
    }

    private var status: String {
        guard friend.online else { return "hors ligne" }
        if friend.presence == .away {
            let m = Int(Date().timeIntervalSince(friend.since) / 60)
            return m < 1 ? "absent" : m < 60 ? "absent · \(m) min" : "absent · \(m / 60) h"
        }
        switch friend.state {
        case .working: return "Claude travaille"
        case .approval: return "attend une autorisation"
        case .waiting: return "attend sa réponse"
        case .error: return "a un souci"
        case .sleeping: return "sur son Mac"
        case .finished, .idle, .dizzy: return "sur son Mac"
        }
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
                        Spacer(minLength: 4)
                        Text("⌥⇧Y · ⌥⇧N").font(Fonts.caption).foregroundStyle(Color.faint)
                            .help("⌥⇧Y autoriser, ⌥⇧N refuser, depuis n'importe quelle app")
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
                if let t = store.focused?.turn { TurnSummary(turn: t) }
                HStack(spacing: 8) {
                    if let s = store.focused {
                        Button("Voir dans \(s.place)") { store.jump(to: s) }.buttonStyle(Pill(primary: true))
                    }
                    Button("OK") { store.dismissCurrent() }.buttonStyle(Pill())
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
    }
}

/// « 4 fichiers en 6 min · +120 −34 · 12k tokens · contexte 84k », puis les fichiers à ouvrir dans VS Code.
private struct TurnSummary: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(turn.text).foregroundStyle(Color.muted)
                if let a = turn.added, let r = turn.removed, a + r > 0 {
                    (Text("+\(a) ").foregroundColor(.success) + Text("−\(r)").foregroundColor(.danger))
                        .monospacedDigit()
                        .help("Lignes modifiées dans ces fichiers depuis le dernier commit")
                }
                if let t = turn.tokens {
                    Text("· " + t).foregroundStyle(Color.faint)
                        .help("Tokens écrits par Claude pendant la demande · taille du contexte qu'il relit à chaque message")
                }
            }
            if !turn.files.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.files.prefix(4), id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { open(path) }
                            .buttonStyle(Chip())
                            .frame(maxWidth: 120)
                            .help("Ouvrir \(path) dans VS Code")
                    }
                    if turn.files.count > 4 { Text("+\(turn.files.count - 4)").foregroundStyle(Color.muted) }
                }
            }
        }
        .font(Fonts.label)
        .lineLimit(1)
    }

    private func open(_ path: String) {
        var c = URLComponents()
        c.scheme = "vscode"
        c.host = "file"
        c.path = path
        if let url = c.url { NSWorkspace.shared.open(url) }
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
                        Button("Voir dans \(s.place)") { store.jump(to: s) }.buttonStyle(Pill(primary: true))
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
            // « Convertir » utilise l'app Convertisseur : sans elle, toute la place est pour l'étagère.
            let converter = Store.engine != nil
            DropZone(targeted: $store.dropKeep, color: "#3B9EFF", title: "Garder ici",
                     tags: ["Le temps de le coller ailleurs"], leading: 112) { store.keep($0) }
                .frame(width: converter ? 300 : nil)
            if converter {
                DropZone(targeted: $store.dropTargeted, color: "#34D399", title: "Convertir",
                         tags: ["WebP", "JPG", "PDF"], leading: 18) { store.dropped($0) }
            }
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
