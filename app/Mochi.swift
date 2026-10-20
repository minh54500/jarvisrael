import SwiftUI

// Le Mochi : porté des prototypes de Louis (notch-buddy.html, greeting-v2.html).
// Tout est une fonction du temps : update(now) fait avancer l'état, draw() dessine.

enum BotState: String {
    case idle, working, waiting, approval, finished, error, sleeping, dizzy
}

enum Eye { case dot, wide, happy, content, closed, flat, spiral, heart, star, tired, wink, cup, line }
enum Badge { case dots, bang, question, dot }

struct StateStyle {
    var col: String
    var tint: Double
    var eye: Eye
    var badge: Badge? = nil
    var glow: String
    var glowAlpha: Double
    var tilt = 0.0
    var bounce = false
    var breathe = false
    var zz = false
    var sound: String? = nil
}

let STYLES: [BotState: StateStyle] = [
    .idle: StateStyle(col: "#E6E9EE", tint: 0, eye: .dot, glow: "#FFFFFF", glowAlpha: 0.25),
    .working: StateStyle(col: "#3B9EFF", tint: 0.6, eye: .dot, badge: .dots, glow: "#3B9EFF", glowAlpha: 0.55, sound: "work"),
    .waiting: StateStyle(col: "#22D3EE", tint: 0.6, eye: .dot, badge: .question, glow: "#22D3EE", glowAlpha: 0.55, tilt: 0.17, sound: "question"),
    .approval: StateStyle(col: "#F5A524", tint: 0.7, eye: .wide, badge: .bang, glow: "#F5A524", glowAlpha: 0.6, bounce: true, sound: "approval"),
    .finished: StateStyle(col: "#34D399", tint: 0.35, eye: .happy, badge: .dot, glow: "#34D399", glowAlpha: 0.5, sound: "finish"),
    .error: StateStyle(col: "#F4505E", tint: 0.7, eye: .flat, badge: .dot, glow: "#F4505E", glowAlpha: 0.55, sound: "error"),
    .sleeping: StateStyle(col: "#94A3B8", tint: 0.3, eye: .closed, glow: "#94A3B8", glowAlpha: 0.2, breathe: true, zz: true),
    .dizzy: StateStyle(col: "#F472B6", tint: 0.6, eye: .spiral, glow: "#F472B6", glowAlpha: 0.55, sound: "dizzy"),
]

private let WHITE0 = RGB(hex: "#FBFBFC"), WHITE1 = RGB(hex: "#E7E9EC")
private let INK = Color(hex: "#16171A")
private let ASPECT = 1.34

final class Mochi {
    struct Anim {
        var lookX = 0.0, lookY = 0.0, tilt = 0.0, open = 1.0, sx = 1.0, sy = 1.0, ox = 0.0, oy = 0.0
        var tint = 0.0, handL = 0.0, handR = 0.0, blush = 0.0, es = 1.0, badgeS = 0.0, roll = 0.0, mouth = 0.0
    }
    typealias Key = WritableKeyPath<Anim, Double>
    private struct Tween {
        let key: Key
        let keys: [(Double, Double, (Double) -> Double)]  // (valeur, durée, easing)
        var i = 0
        var from: Double
        var t0: Double
        var after: (() -> Void)?
    }
    private struct Particle {
        enum Kind { case z, spark, heart, star, sweat }
        var kind: Kind, x, y, vx, vy, age, life, rot, size: Double
    }

    var s = Anim()
    private var tg = Anim()
    private var tweens: [Tween] = []
    private var locked = Set<Key>()
    private var timers: [(Double, () -> Void)] = []
    private var particles: [Particle] = []

    private(set) var state: BotState = .idle
    private var style = STYLES[.idle]!
    private var col = RGB(hex: "#E6E9EE"), colT = RGB(hex: "#E6E9EE")
    private var eyeOverride: Eye?
    private var overrideUntil = 0.0
    private var badge: Badge?
    private var badgeCol = RGB(hex: "#FFFFFF")
    private var badgeKey = "none"
    private var nextBlink = 0.0
    private var waveStart = -10.0, waveUntil = 0.0
    private var lastAmbient = 0.0
    private var last = 0.0
    private let born: Double
    private var now = 0.0

    let mini: Bool
    let bodyColor: RGB?
    /// Regard demandé de l'extérieur (souris), -1…1, y positif = vers le bas.
    var lookTarget = (x: 0.0, y: 0.0)
    /// Coucou d'entrée en cours (instant de départ).
    private(set) var greetStart: Double?
    private var greet = (scale: 1.0, dx: 0.0, dy: 0.0, eyeDrop: 0.0, halo: 1.0)

    init(mini: Bool = false, bodyColor: String? = nil, now: Double) {
        self.mini = mini
        self.bodyColor = bodyColor.map { RGB(hex: $0) }
        born = now - Double.random(in: 0...5)
        last = now
        self.now = now
        nextBlink = now + 1.5 + Double.random(in: 0...2)
    }

    // MARK: Animations

    func anim(_ key: Key, _ keys: [(Double, Double, (Double) -> Double)], after: (() -> Void)? = nil) {
        tweens.removeAll { $0.key == key }
        tweens.append(Tween(key: key, keys: keys, from: s[keyPath: key], t0: now, after: after))
        locked.insert(key)
    }

    func later(_ delay: Double, _ action: @escaping () -> Void) { timers.append((now + delay, action)) }

    func setState(_ n: BotState, force: Bool = false) {
        guard force || n != state, let st = STYLES[n] else { return }
        state = n
        style = st
        colT = RGB(hex: st.col)
        tg.tint = st.tint
        tg.tilt = st.tilt
        setBadge(st.badge, st.col)
        switch n {
        case .finished:
            roll(0.95, turns: 1)
            later(0.5) { self.emit(.spark, 5) }
        case .error:
            anim(\.ox, [(0.08, 0.05, Ease.out), (-0.08, 0.07, Ease.inOut), (0.05, 0.07, Ease.inOut), (0, 0.09, Ease.out)])
        case .approval:
            anim(\.oy, [(-0.2, 0.15, Ease.out), (0, 0.3, Ease.back)])
        case .dizzy:
            roll(1.3, turns: 2)
        default:
            blink()
        }
    }

    private func setBadge(_ b: Badge?, _ hex: String) {
        let key = b.map { "\($0)\(hex)" } ?? "none"
        guard key != badgeKey else { return }
        badgeKey = key
        anim(\.badgeS, [(0, 0.09, Ease.inOut)])
        later(0.1) {
            guard self.badgeKey == key else { return }
            self.badge = b
            self.badgeCol = RGB(hex: hex)
            if b != nil { self.anim(\.badgeS, [(1, 0.28, Ease.back)]) }
        }
    }

    func blink() {
        guard !locked.contains(\.open) else { return }
        anim(\.open, [(0.06, 0.07, Ease.inOut), (1, 0.13, Ease.out)])
    }

    func squash() {
        anim(\.sy, [(0.78, 0.07, Ease.out), (1.1, 0.13, Ease.out), (1, 0.17, Ease.inOut)])
        anim(\.sx, [(1.16, 0.07, Ease.out), (0.95, 0.13, Ease.out), (1, 0.17, Ease.inOut)])
    }

    func roll(_ d: Double, turns: Double) {
        s.roll = 0
        anim(\.roll, [(2 * .pi * turns, d, Ease.inOut)]) { self.s.roll = 0; self.tg.roll = 0 }
    }

    /// Petit coucou de la main (survol de l'encoche compacte).
    func wave() {
        anim(\.handL, [(1, 0.28, Ease.back)])
        anim(\.handR, [(1, 0.28, Ease.back)])
        waveStart = now
        waveUntil = now + 1.5
        emote(.happy, 1.5)
        later(1.55) {
            self.anim(\.handL, [(0, 0.24, Ease.inOut)])
            self.anim(\.handR, [(0, 0.24, Ease.inOut)])
        }
    }

    enum Emote { case love, surprised, proud, wink, yawn, happy, annoyed, gulp }

    func emote(_ e: Emote, _ d: Double = 1.8) {
        overrideUntil = now + d
        switch e {
        case .love:
            eyeOverride = .heart
            anim(\.blush, [(1, 0.3, Ease.out), (1, d - 0.6, Ease.lin), (0, 0.3, Ease.inOut)])
            emit(.heart, 4)
            anim(\.oy, [(-0.1, 0.16, Ease.out), (0, 0.3, Ease.back)])
        case .surprised:
            eyeOverride = .dot
            anim(\.oy, [(-0.3, 0.14, Ease.out), (0, 0.38, Ease.back)])
            anim(\.es, [(1.25, 0.12, Ease.out), (1, 0.5, Ease.inOut)])
        case .proud:
            eyeOverride = .star
            emit(.star, 5)
            anim(\.tilt, [(-0.14, 0.22, Ease.out), (-0.14, d - 0.5, Ease.lin), (0, 0.28, Ease.inOut)])
        case .wink:
            eyeOverride = .wink
            anim(\.tilt, [(0.12, 0.16, Ease.out), (0.12, d - 0.4, Ease.lin), (0, 0.24, Ease.inOut)])
        case .yawn:
            eyeOverride = .tired
            anim(\.sy, [(1.12, 0.5, Ease.inOut), (1, 0.5, Ease.inOut)])
            anim(\.sx, [(0.94, 0.5, Ease.inOut), (1, 0.5, Ease.inOut)])
            later(0.7) { self.eyeOverride = .closed; self.emit(.z, 2) }
        case .happy:
            eyeOverride = .happy
            anim(\.blush, [(0.6, 0.2, Ease.out), (0, 0.6, Ease.inOut)])
        case .annoyed:
            eyeOverride = .line
        case .gulp:
            eyeOverride = .content
            anim(\.mouth, [(0, 0.09, Ease.cubicIn)])
            anim(\.sy, [(0.82, 0.07, Ease.out), (1.1, 0.13, Ease.out), (1, 0.15, Ease.inOut)])
            anim(\.sx, [(1.14, 0.07, Ease.out), (0.95, 0.13, Ease.out), (1, 0.15, Ease.inOut)])
        }
    }

    /// Bouche ouverte (fichier qui approche) : 0 fermée, 0,42 ouverte, 0,5 grande ouverte.
    func setMouth(_ v: Double) { tg.mouth = v }

    private func emit(_ kind: Particle.Kind, _ n: Int) {
        for i in 0..<n {
            particles.append(Particle(
                kind: kind,
                x: Double.random(in: -0.45...0.45) + (kind == .z ? 0.55 : 0),
                y: -0.7 - Double.random(in: 0...0.2),
                vx: Double.random(in: -0.17...0.17) + (kind == .z ? 0.18 : 0),
                vy: -(0.45 + Double.random(in: 0...0.35)),
                age: -Double(i) * 0.14,
                life: 1.3 + Double.random(in: 0...0.5),
                rot: Double.random(in: 0...6),
                size: 0.15 + Double.random(in: 0...0.08)))
        }
    }

    func startGreeting() { greetStart = now }

    // MARK: Mise à jour

    func update(_ now: Double) {
        guard now > self.now || last == now else { return }
        let dt = min(0.05, now - last)
        last = now
        self.now = now
        let t = now - born

        for (at, action) in timers where at <= now { action() }
        timers.removeAll { $0.0 <= now }

        var done: [Tween] = []
        for idx in tweens.indices {
            var tw = tweens[idx]
            while tw.i < tw.keys.count {
                let k = tw.keys[tw.i]
                let p = k.1 <= 0 ? 1 : clamp((now - tw.t0) / k.1, 0, 1)
                s[keyPath: tw.key] = tw.from + (k.0 - tw.from) * k.2(p)
                if p < 1 { break }
                tw.from = k.0
                tw.t0 += k.1
                tw.i += 1
            }
            tweens[idx] = tw
            if tw.i >= tw.keys.count { done.append(tw) }
        }
        for tw in done {
            tweens.removeAll { $0.key == tw.key && $0.i >= $0.keys.count }
            locked.remove(tw.key)
            tg[keyPath: tw.key] = tw.keys.last!.0
            tw.after?()
        }

        // Cibles selon l'état
        var lx = lookTarget.x * 0.7, ly = lookTarget.y * 0.6
        if state == .sleeping { lx = 0; ly = 0.35 }
        if state == .dizzy { lx = sin(t * 9) * 0.25 }
        tg.lookX = lx
        tg.lookY = ly
        tg.tilt = style.tilt
        tg.oy = style.bounce ? -abs(sin(t * 5.2)) * 0.07 : 0
        tg.sy = style.breathe ? 1 + sin(t * 1.8) * 0.035 : 1
        tg.sx = style.breathe ? 1 - sin(t * 1.8) * 0.02 : 1

        let kLook = 1 - pow(0.0025, dt), kGen = 1 - pow(0.0008, dt)
        let keys: [Key] = [\.lookX, \.lookY, \.tilt, \.open, \.sx, \.sy, \.ox, \.oy, \.tint, \.handL, \.handR, \.blush, \.es, \.badgeS, \.roll, \.mouth]
        for key in keys where !locked.contains(key) {
            let k = (key == \Anim.lookX || key == \Anim.lookY) ? kLook : kGen
            s[keyPath: key] += (tg[keyPath: key] - s[keyPath: key]) * k
        }
        col = col.mix(colT, 1 - pow(0.002, dt))

        if now > nextBlink {
            if state != .sleeping && state != .dizzy {
                blink()
                if Double.random(in: 0...1) < 0.22 { later(0.23) { self.blink() } }
            }
            nextBlink = now + 2.2 + Double.random(in: 0...3.2)
        }
        if eyeOverride != nil && now > overrideUntil { eyeOverride = nil }
        if !mini && now - lastAmbient > 1.3 {
            lastAmbient = now
            if style.zz { emit(.z, 1) }
        }
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.life }

        applyGreeting(now)
    }

    /// Coucou d'entrée : reprise de greetPose() de greeting-v2.html, en unités de hauteur du corps.
    private func applyGreeting(_ now: Double) {
        guard let start = greetStart else { greet = (1, 0, 0, 0, 1); return }
        let t = now - start
        if t > 4.0 { greetStart = nil; greet = (1, 0, 0, 0, 1); return }
        let gg = Ease.back(seg(t, 0.02, 0.45))
        var g = (scale: lerp(3.0 / 58, 1, gg), dx: 0.0, dy: lerp(-1.25, 0, Ease.out(seg(t, 0.02, 0.45))), eyeDrop: 0.0,
                 halo: Ease.out(seg(t, 0.3, 0.7)))
        // plongeon en avant : le corps s'écrase, les yeux glissent vers le bas
        if t >= 1.25 && t < 1.52 {
            let k = sin(.pi * seg(t, 1.25, 1.52))
            g.dy += 0.22 * k
            s.sy = 1 - 0.06 * k
            s.sx = 1 + 0.04 * k
            g.eyeDrop = k
        }
        // coucou : balancement gauche-droite
        if t >= 1.52 && t < 2.8 {
            let w = t - 1.52, fade = 1 - seg(t, 2.58, 2.8)
            g.dx = sin(w * 2 * .pi * 0.9) * ASPECT * 0.05 * fade
            s.tilt = sin(w * 2 * .pi * 0.9 + 0.6) * 0.05 * fade
            g.dy += sin(w * 2 * .pi * 1.8) * 0.014 * fade
        }
        if t >= 2.58 && t < 3.2 { g.dy += 0.12 * sin(.pi * seg(t, 2.58, 3.2)) }
        // yeux
        eyeOverride = nil
        if t >= 0.6 && t < 0.82 { eyeOverride = .happy }
        if (t >= 2.45 && t < 2.58) || (t >= 2.85 && t < 3.2) { eyeOverride = .content }
        func blinkAt(_ tb: Double) -> Double { let k = seg(t, tb, tb + 0.12); return k > 0 && k < 1 ? 1 - sin(.pi * k) * 0.94 : 1 }
        s.open = min(blinkAt(1.95), blinkAt(3.8))
        // regard
        if t >= 0.82 && t < 1.25 { s.lookX = 0; s.lookY = -0.2 }
        if t >= 1.52 && t < 2.45 { s.lookX = 0.55; s.lookY = -0.45 }
        if t >= 2.45 && t < 3.2 { s.lookX = -0.3; s.lookY = 0.6 }
        // mains
        s.handL = t < 2.58 ? Ease.back(seg(t, 1.36, 1.5)) : 1 - Ease.cubicIn(seg(t, 2.58, 2.77))
        s.handR = t < 2.58 ? Ease.back(seg(t, 1.4, 1.54)) : 1 - Ease.cubicIn(seg(t, 2.61, 2.8))
        if t >= 1.52 && t < 2.58 { waveStart = start + 1.52; waveUntil = start + 2.58 }
        greet = g
    }

    // MARK: Dessin

    /// Dessine le Mochi centré en (cx, cy), `hb` = hauteur du corps en points.
    func draw(_ ctx: GraphicsContext, cx: Double, cy: Double, hb: Double, alpha: Double = 1) {
        let hbE = hb * greet.scale, hh = hbE / 2, hw = hh * ASPECT
        guard hh > 0.4 else { return }
        var c = ctx
        c.opacity = alpha
        let px = cx + (s.ox + greet.dx) * hbE, py = cy + (s.oy + greet.dy) * hbE

        // halo
        if !mini {
            let glow = RGB(hex: style.glow), a = style.glowAlpha * 0.6 * greet.halo
            let R = hw * 2.2
            c.fill(Path(ellipseIn: CGRect(cx: px, cy: py, w: 2 * R, h: 2 * R)),
                   with: .radialGradient(Gradient(colors: [glow.color(a), glow.color(0)]),
                                         center: CGPoint(x: px, y: py), startRadius: hh * 0.3, endRadius: R))
        }

        var b = c
        b.translateBy(x: px, y: py)
        b.rotate(by: .radians(s.tilt))
        b.scaleBy(x: s.sx, y: s.sy)

        drawHands(b, hw: hw, hh: hh)

        let body = superellipse(hw, hh)
        let (c0, c1) = bodyColor.map { ($0.mix(RGB(255, 255, 255), 0.35), $0.mix(RGB(0, 0, 0), 0.15)) } ?? (WHITE0, WHITE1)
        b.fill(body, with: .linearGradient(Gradient(colors: [c0.color(), c1.color()]),
                                           startPoint: CGPoint(x: hw * 0.6, y: -hh), endPoint: CGPoint(x: -hw * 0.6, y: hh)))
        if bodyColor == nil && s.tint > 0.01 {
            b.fill(body, with: .linearGradient(Gradient(colors: [col.color(s.tint), col.color(0)]),
                                               startPoint: CGPoint(x: 0, y: hh), endPoint: CGPoint(x: 0, y: -hh * 0.1)))
        }
        b.stroke(body, with: .color(.black.opacity(0.08)), lineWidth: 0.6)

        var inner = b
        inner.clip(to: body)
        // joues
        if s.blush > 0.01 {
            for sd in [-1.0, 1.0] {
                inner.fill(Path(ellipseIn: CGRect(cx: sd * hw * 0.55 + s.lookX * hw * 0.2, cy: hh * 0.38, w: hh * 0.42, h: hh * 0.22)),
                           with: .color(Color(.sRGB, red: 1, green: 0.47, blue: 0.59, opacity: 0.5 * s.blush)))
            }
        }
        // bouche (boîte à fichiers)
        if s.mouth > 0.01 {
            let mw = hw * 1.5, mh = s.mouth * hh * 0.95, my = -hh * 0.62
            let mouth = Path(roundedRect: CGRect(x: -mw / 2, y: my, width: mw, height: mh), cornerRadius: mh / 2)
            inner.fill(mouth, with: .linearGradient(Gradient(colors: [Color(hex: "#030304"), Color(hex: "#101114")]),
                                                    startPoint: CGPoint(x: 0, y: my), endPoint: CGPoint(x: 0, y: my + mh)))
        }
        // yeux
        let shape = eyeOverride ?? style.eye
        let er = hbE * 0.06 * s.es, sp = hbE * 0.19
        let lx = s.lookX * hw * 0.42
        var ly = s.lookY * hh * 0.28 + hh * 0.12 + greet.eyeDrop * hh * 1.25 + s.mouth * hh * 0.5
        if s.roll > 0.001 {  // les yeux font le tour du corps
            let f = (s.roll / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            ly += f < 0.5 ? f * 2 * hh * 1.5 : -(1 - f) * 2 * hh * 1.5
        }
        for sd in [-1.0, 1.0] {
            drawEye(inner, shape, x: sd * sp + lx, y: ly, er: er, side: sd)
        }

        // badge
        if let badge, s.badgeS > 0.01 {
            var bc = b
            bc.translateBy(x: -hw * 0.78, y: -hh * 0.72)
            bc.scaleBy(x: s.badgeS * (mini ? 1.3 : 1), y: s.badgeS * (mini ? 1.3 : 1))
            let br = hh * 0.3
            bc.fill(Path(ellipseIn: CGRect(cx: 0, cy: 0, w: 2 * (br + hh * 0.07), h: 2 * (br + hh * 0.07))), with: .color(.black))
            bc.fill(Path(ellipseIn: CGRect(cx: 0, cy: 0, w: 2 * br, h: 2 * br)), with: .color(badgeCol.color()))
            if !mini {
                switch badge {
                case .dots:
                    for i in 0..<3 {
                        let ph = ((now * 2.4 - Double(i) * 0.22).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                        let r = br * 0.17 * (1 + 0.4 * max(0, sin(ph * 2 * .pi)))
                        bc.fill(Path(ellipseIn: CGRect(cx: Double(i - 1) * br * 0.5, cy: 0, w: 2 * r, h: 2 * r)), with: .color(Color(hex: "#0B1B3A")))
                    }
                case .bang, .question:
                    bc.draw(Text(badge == .bang ? "!" : "?").font(.system(size: br * 1.3, weight: .heavy)).foregroundColor(.white),
                            at: CGPoint(x: 0, y: br * 0.02))
                case .dot:
                    break
                }
            }
        }

        // particules
        let R = hh * 1.1
        for p in particles where p.age >= 0 {
            let k = p.age / p.life, a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8
            let x = px + (p.x + p.vx * p.age) * R * 1.3, y = py + (p.y + p.vy * p.age) * R * 1.3
            let sz = R * p.size * (1 + k * 0.4)
            var pc = c
            pc.opacity = alpha * clamp(a, 0, 1)
            pc.translateBy(x: x, y: y)
            switch p.kind {
            case .heart:
                pc.rotate(by: .radians(sin(p.age * 6) * 0.3))
                pc.fill(heartPath(sz), with: .color(Color(hex: "#FF4D6D")))
            case .star:
                pc.rotate(by: .radians(p.rot + p.age * 2))
                pc.fill(starPath(sz, sz * 0.45), with: .color(Color(hex: "#F7B32B")))
            case .spark:
                pc.rotate(by: .radians(p.rot))
                pc.fill(starPath(sz * 0.8, sz * 0.18), with: .color(.white))
            case .sweat:
                var d = Path()
                d.move(to: CGPoint(x: 0, y: -sz))
                d.addQuadCurve(to: CGPoint(x: 0, y: sz * 0.6), control: CGPoint(x: sz * 0.8, y: sz * 0.2))
                d.addQuadCurve(to: CGPoint(x: 0, y: -sz), control: CGPoint(x: -sz * 0.8, y: sz * 0.2))
                pc.fill(d, with: .color(Color(hex: "#7CC7FF")))
            case .z:
                pc.draw(Text("z").font(.system(size: sz * 1.9, weight: .bold)).foregroundColor(Color(hex: "#D2DCEB")), at: .zero)
            }
        }
    }

    private func drawHands(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let hb = hh * 2
        let waving = now < waveUntil
        let wave = now - waveStart
        let white = Gradient(colors: [WHITE0.color(), WHITE1.color()])
        // main gauche : petite boule
        if s.handL > 0.01 {
            let k = s.handL, r = hb * 0.15 * k
            var y = lerp(hh * 0.85, hh * 0.62, k)
            let x = lerp(-hw * 0.35, -hw - hb * 0.22, k)
            if waving { y += sin(wave * 6) * hb * 0.02 }
            let ball = Path(ellipseIn: CGRect(cx: x, cy: y, w: 2 * r, h: 2 * r))
            ctx.fill(ball, with: .linearGradient(white, startPoint: CGPoint(x: x + r, y: y - r), endPoint: CGPoint(x: x - r, y: y + r)))
            ctx.stroke(ball, with: .color(.black.opacity(0.08)), lineWidth: 0.6)
        }
        // main droite : capsule qui s'agite
        if s.handR > 0.01 {
            let k = s.handR, L = hb * 0.4 * k, T = hb * 0.22 * k
            var x = lerp(hw * 0.35, hw + hb * 0.2, k), y = lerp(hh * 0.85, hh * 0.2, k), ang = -0.61
            if waving {
                let w = wave * 2 * .pi * 2.5
                ang += sin(w) * 0.21
                y += sin(w + 0.8) * hb * 0.04
                x += cos(w) * hb * 0.015
            }
            var hc = ctx
            hc.translateBy(x: x, y: y)
            hc.rotate(by: .radians(ang))
            let cap = Path(roundedRect: CGRect(x: -L / 2, y: -T / 2, width: L, height: T), cornerRadius: T / 2)
            hc.fill(cap, with: .linearGradient(white, startPoint: CGPoint(x: L / 2, y: -T / 2), endPoint: CGPoint(x: -L / 2, y: T / 2)))
            hc.stroke(cap, with: .color(.black.opacity(0.08)), lineWidth: 0.6)
        }
    }

    private func drawEye(_ ctx: GraphicsContext, _ shape: Eye, x: Double, y: Double, er: Double, side: Double) {
        let ink = GraphicsContext.Shading.color(INK)
        func arc(_ cy: Double, _ r: Double, _ a0: Double, _ a1: Double, _ w: Double) {
            var p = Path()
            p.addArc(center: CGPoint(x: x, y: cy), radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        switch shape {
        case .dot, .wide:
            let r = shape == .wide ? er * 1.35 : er
            let h = 2 * r * max(0.12, s.open)
            ctx.fill(Path(ellipseIn: CGRect(cx: x, cy: y, w: 2 * r, h: h)), with: ink)
        case .happy:
            arc(y + er * 0.6, er * 1.25, .pi * 1.15, .pi * 1.85, er * 0.95)
        case .content:
            arc(y - er * 0.5, er * 1.25, .pi * 0.15, .pi * 0.85, er * 0.95)
        case .closed:
            arc(y - er * 0.3, er * 1.2, .pi * 0.15, .pi * 0.85, er * 0.7)
        case .flat:
            ctx.fill(Path(roundedRect: CGRect(cx: x, cy: y, w: er * 2.6, h: er * 0.8), cornerRadius: er * 0.4), with: ink)
        case .line:
            var lc = ctx
            lc.translateBy(x: x, y: y)
            lc.rotate(by: .radians(-side * 0.25))
            lc.fill(Path(roundedRect: CGRect(cx: 0, cy: 0, w: er * 2.8, h: er * 0.8), cornerRadius: er * 0.4), with: ink)
        case .tired:
            ctx.fill(Path(roundedRect: CGRect(x: x - er, y: y - er * 0.1, width: 2 * er, height: er * 1.1), cornerRadius: er * 0.55), with: ink)
            ctx.fill(Path(roundedRect: CGRect(cx: x, cy: y - er * 0.2, w: er * 2.6, h: er * 0.5), cornerRadius: er * 0.25), with: ink)
        case .spiral:
            var p = Path()
            var a = 0.0
            while a < 4.4 * .pi {
                let r = er * 0.12 + a * er * 0.1, aa = a + now * 9 * side
                let pt = CGPoint(x: x + cos(aa) * r, y: y + sin(aa) * r)
                a == 0 ? p.move(to: pt) : p.addLine(to: pt)
                a += 0.2
            }
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: er * 0.4, lineCap: .round))
        case .heart:
            var hc = ctx
            hc.translateBy(x: x, y: y)
            hc.fill(heartPath(er * 2.4), with: .color(Color(hex: "#FF4D6D")))
        case .star:
            var sc = ctx
            sc.translateBy(x: x, y: y)
            sc.rotate(by: .radians(now * 1.5 * side))
            sc.fill(starPath(er * 2.1, er * 0.95), with: .color(Color(hex: "#F7B32B")))
        case .wink:
            if side < 0 { drawEye(ctx, .dot, x: x, y: y, er: er, side: side) }
            else { drawEye(ctx, .happy, x: x, y: y, er: er, side: side) }
        case .cup:
            var p = Path()
            p.move(to: CGPoint(x: x - er, y: y - er * 0.6))
            p.addLine(to: CGPoint(x: x + er, y: y - er * 0.6))
            p.addArc(center: CGPoint(x: x, y: y - er * 0.6), radius: er, startAngle: .zero, endAngle: .radians(.pi), clockwise: false)
            p.closeSubpath()
            ctx.fill(p, with: ink)
        }
    }
}
