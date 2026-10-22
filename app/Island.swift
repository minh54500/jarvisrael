import AppKit
import SwiftUI

// L'encoche : sa forme, le bonhomme, le bandeau d'onglets, les bulles et le cadre des panneaux.
// Chaque onglet a ses vues dans app/Panels/.

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

struct IslandRoot: View {
    @ObservedObject var store: Store

    var body: some View {
        let size = store.islandTarget
        let flare = store.mode == .hidden ? 0.0 : 14.0
        let radius = store.mode == .expanded ? 30.0 : store.mode == .peek ? 20.0 : store.mode == .compact ? 14.0 : 10.0
        ZStack(alignment: .top) {
            CamHost()  // la caméra entre potes, sous le noir de l'encoche
            QuickDropsView(store: store)  // les gouttes, qui sortent de sous l'encoche ouverte
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
        .onChange(of: store.mode == .expanded) { _, open in QuickDropsMotion.shared.setVisible(open) }
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
        .opacity(slot.hb < 1 ? 0 : 1)
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
        Button(store.dnd ? "Couper « Ne pas déranger »" : "Ne pas déranger") { store.setDND(!store.dnd) }
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
        Button("Projets récents") { store.show(.projects) }
        Button("Résumé de ma journée") { store.show(.recap); Recap.shared.make() }
        if !Updater.shared.news.isEmpty { Button("Mettre à jour Encoche…") { SettingsWindow.show(.update) } }
        Button("Réglages…") { SettingsWindow.show() }
        Button("Quitter Encoche") { NSApp.terminate(nil) }
    }
}

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
struct PeekView: View {
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
struct ToastPill: View {
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
                case .projects: ProjectsPanel(store: store)
                case .recap: RecapPanel(store: store)
                case .welcome: WelcomePanel(store: store)
                }
            }
            .id(store.view)
            // Fondu enchaîné : le nouvel écran arrive pendant que l'ancien part, sans moment vide entre les deux
            // (avant, la carte « s'éteignait » un dixième de seconde à chaque changement d'onglet).
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)).animation(.easeOut(duration: 0.2)),
                                    removal: .opacity.animation(.easeIn(duration: 0.26))))
            .padding(.top, store.cardTop)
            .padding([.horizontal, .bottom], 10)
        }
        .frame(width: Store.expandedWidth, height: store.viewHeight, alignment: .top)
        .environment(\.sectionTint, store.sectionTint)
        .overlay(alignment: .top) {  // en haut, sous les onglets : jamais sur le champ où tu écris
            if let t = store.toast {
                ToastPill(store: store, toast: t)
                    .padding(.top, store.cardTop + 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
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

/// Claude · Musique · Étagère. L'onglet actif s'élargit avec son nom ; la pastille glisse de l'un à l'autre.
struct Tabs: View {
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
            item(.dev, icon: "square.grid.2x2.fill", title: "Outils", badge: nil, live: Prompter.shared.showing) { store.goTo(.dev) }
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
                if active { Capsule().fill(store.sectionTint?.opacity(0.3) ?? .white.opacity(0.13)).matchedGeometryEffect(id: "tab", in: ns) }
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
struct PulseDot: View {
    let color: Color
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .background(Circle().fill(color.opacity(0.35)).scaleEffect(on && !still ? 2.2 : 1).opacity(on && !still ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
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
