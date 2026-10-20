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
        .foregroundStyle(Color(hex: "#F5F6F8"))
        .font(.system(size: 13))
    }

    /// Bandeau à hauteur de l'encoche : les éléments restent de part et d'autre de la caméra.
    private var header: some View {
        HStack {
            Text("Encoche").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color(hex: "#7B8089"))
            Spacer()
            let n = store.sessions.filter { $0.state == .working || $0.state == .approval || $0.state == .waiting }.count
            if n > 0 { Text("\(n) en cours").font(.system(size: 11.5)).foregroundStyle(Color(hex: "#7B8089")) }
            Button {
                Sound.shared.on.toggle()
                store.objectWillChange.send()
                Sound.shared.play("blip")
            } label: {
                Image(systemName: Sound.shared.on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(hex: "#8E939C")).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Son")
        }
        .padding(.horizontal, 18)
        .frame(height: store.notch.height)
    }
}

// MARK: - Éléments communs

struct Card<Content: View>: View {
    var wash: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color(hex: "#141518")
                    if let wash {
                        RadialGradient(colors: [wash, .clear], center: UnitPoint(x: 0.5, y: 1.3), startRadius: 0, endRadius: 380)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.035)))
    }
}

struct Pill: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(primary ? Color(hex: "#0B0C0E") : Color(hex: "#F1F2F4"))
            .background(Capsule().fill(primary ? Color(hex: "#F5F6F8") : .white.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
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
            Text(suffix).foregroundStyle(Color(hex: "#8E939C"))
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

private func big(_ s: String) -> some View {
    Text(s).font(.system(size: 15, weight: .semibold)).lineLimit(2)
}

private func sub(_ s: String, red: Bool = false) -> some View {
    Text(s).foregroundStyle(red ? Color(hex: "#FF8D97") : Color(hex: "#9398A1")).lineLimit(2)
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
                VStack(alignment: .leading, spacing: 8) {
                    Who(session: store.focused, suffix: "Claude Code")
                    VStack(alignment: .leading, spacing: 6) {
                        let lines = Array((store.focused?.history ?? []).suffix(3))
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            let current = i == lines.count - 1
                            Text(current ? (store.focused?.line ?? line) : line)
                                .font(.system(size: current ? 14 : 12.5, weight: current ? .medium : .regular))
                                .foregroundStyle(current ? Color(hex: "#F5F6F8") : Color(hex: "#5F646D"))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if lines.isEmpty { Text(store.focused?.line ?? "").foregroundStyle(Color(hex: "#9398A1")) }
                    }
                }
                .padding(.leading, 100)
                .padding(.trailing, 12)
            }
            .frame(width: 322)
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.sessions.prefix(4)) { s in
                        Button { store.jump(to: s) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: s.color)).frame(width: 8, height: 8)
                                Text(s.name).fontWeight(.medium).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(label(s.state)).font(.system(size: 11.5)).foregroundStyle(Color(hex: STYLES[s.state]?.col ?? "#9398A1"))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Ouvrir \(s.name) dans VS Code")
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
        case .approval: "attend ton feu vert"
        case .waiting: "attend ta réponse"
        case .finished: "terminé"
        case .error: "erreur"
        case .sleeping, .idle, .dizzy: "au repos"
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
                            Text("+\(store.permissions.count - 1) en attente").font(.system(size: 11.5)).foregroundStyle(Color(hex: "#9398A1"))
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

private struct UploadPanel: View {
    @ObservedObject var store: Store
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: "#121316"))
                .overlay {
                    RadialGradient(colors: [Color(hex: "#34D399", store.dropTargeted ? 0.6 : 0.25), .clear],
                                   center: UnitPoint(x: 0.5, y: 1.4), startRadius: 0, endRadius: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(store.dropTargeted ? Color(hex: "#34D399", 0.55) : .white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 8) {
                big("Dépose tes fichiers ici")
                HStack(spacing: 6) {
                    ForEach(["PDF", "Images", "Dossiers"], id: \.self) {
                        Text($0).font(.system(size: 11)).foregroundStyle(Color(hex: "#B9BDC4"))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.07)))
                    }
                }
            }
            .padding(.leading, 200)
        }
        .onDrop(of: [.fileURL], isTargeted: $store.dropTargeted) { providers in
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
            group.notify(queue: .main) { store.dropped(urls.compactMap { $0 }) }
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
                    Text("Conversion de ").foregroundStyle(Color(hex: "#A9ADB5")) + Text(store.progressLabel).fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(store.progress * 100)) %").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color(hex: "#A9ADB5"))
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
