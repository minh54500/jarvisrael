import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Moteur de rendu (ressorts de l'island et du Mochi, une mise à jour par image)

@MainActor
final class Renderer {
    let store: Store
    private var w: Spring, h: Spring
    private var mx = Spring(27), my = Spring(16), mhb = Spring(0)
    private var last = CACurrentMediaTime()
    private let rings: [(t0: Double, dots: [(a: Double, j: Double, s: Double, al: Double)])]
    private let streaks: [(a: Double, sp: Double, len: Double, t0: Double, col: Color)]

    init(store: Store) {
        self.store = store
        w = Spring(store.notch.width, response: 0.45, damping: 0.78)
        h = Spring(store.notch.height, response: 0.45, damping: 0.78)
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        rings = [0.10, 0.20, 0.30, 0.45, 0.60].map { t0 in
            (t0, (0..<170).map { _ in (rnd() * 2 * .pi, (rnd() - 0.5) * 0.22, 0.7 + rnd() * 0.9, 0.45 + rnd() * 0.55) })
        }
        let cols = ["#3B9EFF", "#F29B38", "#FF5A4E", "#2EC4A0", "#A78BFA"]
        streaks = (0..<16).map { i in
            (Double(i) / 16 * 2 * .pi + (rnd() - 0.5) * 0.3, 230 + rnd() * 260, 6 + rnd() * 9, 0.08 + rnd() * 0.14, Color(hex: cols[i % 5]))
        }
    }

    static var centerX: Double { Store.panelSize.width / 2 }

    var islandRect: CGRect { CGRect(x: Self.centerX - w.v / 2, y: 0, width: w.v, height: h.v) }
    var mochiCenter: CGPoint { CGPoint(x: islandRect.minX + mx.v, y: my.v) }

    func tick() {
        let now = CACurrentMediaTime()
        guard now > last else { return }
        let dt = min(0.05, now - last)
        last = now
        let target = store.islandTarget
        let collapsing = target.height < h.v - 1
        w.response = collapsing ? 0.34 : 0.45
        h.response = w.response
        w.damping = collapsing ? 0.95 : 0.78
        h.damping = w.damping
        w.step(to: target.width, dt: dt)
        h.step(to: target.height, dt: dt)
        let slot = store.mochiSlot
        mx.step(to: slot.x, dt: dt)
        my.step(to: slot.y, dt: dt)
        mhb.step(to: slot.hb, dt: dt)

        let c = mochiCenter, p = store.pointer
        store.mochi.lookTarget = (tanh((p.x - c.x) / 260), tanh((p.y - c.y) / 200))
        store.mochi.update(now)
        for m in store.minis.values { m.update(now) }
    }

    func drawIsland(_ ctx: GraphicsContext) {
        let r = islandRect, f = 14.0
        let radius = min(30, max(10, (r.height - store.notch.height) * 0.3 + 10))
        var p = Path()
        p.move(to: CGPoint(x: r.minX - f, y: 0))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: f), control: CGPoint(x: r.minX, y: 0))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - radius), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: f))
        p.addQuadCurve(to: CGPoint(x: r.maxX + f, y: 0), control: CGPoint(x: r.maxX, y: 0))
        p.closeSubpath()
        ctx.fill(p, with: .color(.black))
    }

    func drawCharacters(_ ctx: GraphicsContext) {
        let r = islandRect
        var c = ctx
        c.clip(to: Path(CGRect(x: r.minX - 20, y: 0, width: r.width + 40, height: r.height + 30)))
        let now = CACurrentMediaTime()

        // ondes et traînées du coucou d'entrée (greeting-v2)
        if store.view == .greeting, store.mode == .expanded, let start = store.mochi.greetStart {
            let t = now - start
            let card = CGRect(x: r.minX + 10, y: 36, width: r.width - 20, height: max(0, r.height - 46))
            var rc = c
            rc.clip(to: Path(roundedRect: card, cornerRadius: 20))
            let cx = r.minX + mx.v, cy = my.v
            for ring in rings {
                let k = seg(t, ring.t0, ring.t0 + 1.35)
                guard k > 0 && k < 1 else { continue }
                let rx = lerp(14, 380, Ease.out(k)), ry = rx * 0.34
                let fade = (1 - k) * (k < 0.08 ? k / 0.08 : 1)
                for d in ring.dots {
                    let rr = 1 + d.j
                    rc.fill(Path(CGRect(x: cx + cos(d.a) * rx * rr, y: cy + sin(d.a) * ry * rr, width: d.s, height: d.s)),
                            with: .color(.white.opacity(d.al * fade)))
                }
            }
            for s in streaks {
                let k = seg(t, s.t0, s.t0 + 0.6)
                guard k > 0 && k < 1 else { continue }
                let dist = s.sp * Ease.out(k) * 0.9 + 10
                var line = Path()
                line.move(to: CGPoint(x: cx + cos(s.a) * (dist - s.len), y: cy + sin(s.a) * (dist - s.len) * 0.42))
                line.addLine(to: CGPoint(x: cx + cos(s.a) * dist, y: cy + sin(s.a) * dist * 0.42))
                rc.stroke(line, with: .color(s.col.opacity(1 - k)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }

        // mini-Mochis des sessions, dans l'oreille droite de l'encoche compacte
        if store.mode == .compact {
            let list = Array(store.sessions.prefix(4))
            let sp = 6.0
            let offsets: [[(Double, Double)]] = [[(0, 0)], [(-sp, 0), (sp, 0)], [(-sp, -sp), (sp, -sp), (0, sp)], [(-sp, -sp), (sp, -sp), (-sp, sp), (sp, sp)]]
            let alpha = clamp((r.width - store.notch.width) / 104, 0, 1)
            for (i, s) in list.enumerated() {
                let o = offsets[list.count - 1][i]
                store.minis[s.id]?.draw(c, cx: r.maxX - 27 + o.0, cy: store.notch.height / 2 + o.1, hb: list.count == 1 ? 13 : 7.5, alpha: alpha)
            }
        }

        if mhb.v > 0.5 {
            let alpha = store.mode == .hidden ? clamp(mhb.v / 17, 0, 1) : 1
            store.mochi.draw(c, cx: r.minX + mx.v, cy: my.v, hb: mhb.v, alpha: alpha)
        }
    }
}

// MARK: - Racine du panneau

struct IslandRoot: View {
    @ObservedObject var store: Store
    let renderer: Renderer
    @State private var animating = true

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.animation(paused: !animating)) { _ in
                Canvas { ctx, _ in
                    renderer.tick()
                    renderer.drawIsland(ctx)
                }
            }
            IslandContent(store: store)
                .offset(x: 0, y: 0)
            TimelineView(.animation(paused: !animating)) { _ in
                Canvas { ctx, _ in
                    renderer.tick()
                    renderer.drawCharacters(ctx)
                }
            }
            .allowsHitTesting(false)
            mochiHitTarget
        }
        .frame(width: Store.panelSize.width, height: Store.panelSize.height, alignment: .top)
        .onChange(of: store.mode) { _, mode in
            if mode == .hidden {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if store.mode == .hidden { animating = false } }
            } else {
                animating = true
            }
        }
    }

    /// Zone cliquable sur le Mochi : claques et menu (clic droit).
    private var mochiHitTarget: some View {
        let slot = store.mochiSlot, size = store.islandTarget
        let x = Renderer.centerX - size.width / 2 + slot.x
        return Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: max(24, slot.hb * 1.5), height: max(24, slot.hb * 1.5))
            .position(x: x, y: slot.y)
            .onTapGesture { store.mochiTapped() }
            .contextMenu { SettingsMenu(store: store) }
            .opacity(store.mode == .hidden ? 0 : 1)
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
                case .greeting: Card(wash: .white.opacity(0.06)) { Color.clear }
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
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)).animation(.easeOut(duration: 0.28).delay(0.14)),
                                    removal: .opacity.animation(.easeIn(duration: 0.12))))
            .padding(.top, 36)
            .padding([.horizontal, .bottom], 10)
        }
        .frame(width: Store.expandedWidth, height: store.viewHeight, alignment: .top)
        .opacity(store.mode == .expanded ? 1 : 0)
        .animation(store.mode == .expanded ? .easeOut(duration: 0.25).delay(0.16) : .easeIn(duration: 0.1), value: store.mode)
        .allowsHitTesting(store.mode == .expanded)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color(hex: "#F5F6F8"))
        .font(.system(size: 13))
    }

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
        .padding(.horizontal, 16)
        .frame(height: 34)
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
