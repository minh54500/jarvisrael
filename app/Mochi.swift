import SwiftUI

// Le Mochi : porté des prototypes de Louis (notch-buddy.html, greeting-v2.html).
// Tout est une fonction du temps : update(now) fait avancer l'état, draw() dessine.

enum BotState: String {
    case idle, working, waiting, approval, finished, error, sleeping, dizzy
}

enum Eye { case dot, wide, happy, content, closed, flat, spiral, heart, star, tired, wink, cup, line, focus }
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
    .idle: StateStyle(col: "#E6E9EE", tint: 0, eye: .dot, glow: "#9F5BFF", glowAlpha: 0.35),
    .working: StateStyle(col: "#3B9EFF", tint: 0.6, eye: .focus, badge: .dots, glow: "#3B9EFF", glowAlpha: 0.55, sound: "work"),
    .waiting: StateStyle(col: "#22D3EE", tint: 0.6, eye: .dot, badge: .question, glow: "#22D3EE", glowAlpha: 0.55, tilt: 0.17, sound: "question"),
    .approval: StateStyle(col: "#F5A524", tint: 0.7, eye: .wide, badge: .bang, glow: "#F5A524", glowAlpha: 0.6, bounce: true, sound: "approval"),
    .finished: StateStyle(col: "#34D399", tint: 0.35, eye: .happy, badge: .dot, glow: "#34D399", glowAlpha: 0.5, sound: "finish"),
    .error: StateStyle(col: "#F4505E", tint: 0.7, eye: .flat, badge: .dot, glow: "#F4505E", glowAlpha: 0.55, sound: "error"),
    .sleeping: StateStyle(col: "#94A3B8", tint: 0.3, eye: .closed, glow: "#94A3B8", glowAlpha: 0.2, breathe: true, zz: true),
    .dizzy: StateStyle(col: "#F472B6", tint: 0.6, eye: .spiral, glow: "#F472B6", glowAlpha: 0.55, sound: "dizzy"),
]

// Galet néon : dégradé rose → violet, reflet en haut à gauche, lueur violette ; yeux blanc-cyan qui brillent.
private let EYE = Color(hex: "#EFFCFF"), EYE_GLOW = Color(hex: "#4FD3FF")
private let INK = Color(hex: "#16171A")
private let ASPECT = 1.2

final class Mochi {
    struct Anim {
        var lookX = 0.0, lookY = 0.0, tilt = 0.0, open = 1.0, sx = 1.0, sy = 1.0, ox = 0.0, oy = 0.0
        var tint = 0.0, blush = 0.0, es = 1.0, badgeS = 0.0, roll = 0.0, mouth = 0.0
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
    private var lastAmbient = 0.0
    private var last = 0.0
    private let born: Double
    private var now = 0.0

    let mini: Bool
    let bodyColor: RGB?
    /// Couleurs et accessoire (voir Skins.swift).
    var skin: Skin
    /// Couleur choisie par l'utilisateur, à la place de celles du skin.
    var tint: String?    /// Regard demandé de l'extérieur (souris), -1…1, y positif = vers le bas.
    var lookTarget = (x: 0.0, y: 0.0)
    /// Coucou d'entrée en cours (instant de départ).
    private(set) var greetStart: Double?
    private var greet = (scale: 1.0, dx: 0.0, dy: 0.0, eyeDrop: 0.0, halo: 1.0)

    init(mini: Bool = false, bodyColor: String? = nil, skin: Skin = .current, tint: String? = Skin.tint, now: Double) {
        self.skin = skin
        self.tint = tint
        self.mini = mini
        self.bodyColor = bodyColor.map { RGB(hex: $0) }
        born = now - Double.random(in: 0...5)
        last = now
        self.now = now
        nextBlink = now + 1.5 + Double.random(in: 0...2)
    }

    // MARK: Animations

    /// Horloge réelle : les actions démarrent maintenant, même si le Mochi était en pause (caché).
    private var clock: Double { CACurrentMediaTime() }

    func anim(_ key: Key, _ keys: [(Double, Double, (Double) -> Double)], after: (() -> Void)? = nil) {
        tweens.removeAll { $0.key == key }
        tweens.append(Tween(key: key, keys: keys, from: s[keyPath: key], t0: clock, after: after))
        locked.insert(key)
    }

    func later(_ delay: Double, _ action: @escaping () -> Void) { timers.append((clock + delay, action)) }

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

    enum Emote { case love, surprised, proud, wink, yawn, happy, annoyed, gulp, worried }

    func emote(_ e: Emote, _ d: Double = 1.8) {
        overrideUntil = clock + d
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
        case .worried:
            eyeOverride = .flat
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

    func startGreeting() { greetStart = clock }

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
        let keys: [Key] = [\.lookX, \.lookY, \.tilt, \.open, \.sx, \.sy, \.ox, \.oy, \.tint, \.blush, \.es, \.badgeS, \.roll, \.mouth]
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
            let glow = RGB(hex: state == .idle ? aura : style.glow), a = style.glowAlpha * 0.6 * greet.halo
            let R = hw * 2.2
            c.fill(Path(ellipseIn: CGRect(cx: px, cy: py, w: 2 * R, h: 2 * R)),
                   with: .radialGradient(Gradient(colors: [glow.color(a), glow.color(0)]),
                                         center: CGPoint(x: px, y: py), startRadius: hh * 0.3, endRadius: R))
        }

        var b = c
        b.translateBy(x: px, y: py)
        b.rotate(by: .radians(s.tilt))
        b.scaleBy(x: s.sx, y: s.sy)

        let body = pebblePath(hw, hh)
        let (c0, c1) = palette
        if !mini {  // lueur douce autour du galet
            // Traits de plus en plus fins et opaques autour du contour : une lueur sans flou
            // (un flou recalculé 30 fois par seconde coûtait plus que tout le reste du dessin).
            for (w, a) in [(0.62, 0.07), (0.44, 0.1), (0.28, 0.14), (0.14, 0.2)] {
                b.stroke(body, with: .color(RGB(hex: aura).color(a * greet.halo)), style: StrokeStyle(lineWidth: hh * w, lineJoin: .round))
            }
        }
        b.fill(body, with: .linearGradient(Gradient(colors: [c0.color(), c1.color()]),
                                           startPoint: CGPoint(x: 0, y: -hh), endPoint: CGPoint(x: 0, y: hh)))
        if bodyColor == nil && s.tint > 0.01 {  // l'état de Claude teinte le bas du galet
            b.fill(body, with: .linearGradient(Gradient(colors: [col.color(s.tint * 0.55), col.color(0)]),
                                               startPoint: CGPoint(x: 0, y: hh), endPoint: CGPoint(x: 0, y: -hh * 0.1)))
        }
        if !mini {  // reflet
            var shine = Path()
            shine.move(to: CGPoint(x: -hw * 0.74, y: -hh * 0.4))
            shine.addQuadCurve(to: CGPoint(x: -hw * 0.44, y: -hh * 0.76), control: CGPoint(x: -hw * 0.7, y: -hh * 0.68))
            b.stroke(shine, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: hh * 0.09, lineCap: .round))
        }

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
        let er = hbE * 0.1 * s.es, sp = hbE * 0.21
        let lx = s.lookX * hw * 0.42
        var ly = s.lookY * hh * 0.28 - hh * 0.02 + greet.eyeDrop * hh * 1.25 + s.mouth * hh * 0.5
        if s.roll > 0.001 {  // les yeux font le tour du corps
            let f = (s.roll / (2 * .pi)).truncatingRemainder(dividingBy: 1)
            ly += f < 0.5 ? f * 2 * hh * 1.5 : -(1 - f) * 2 * hh * 1.5
        }
        if !mini {  // halo cyan des yeux : le même œil, plus grand et transparent, deux fois
            for (k, a) in [(1.7, 0.16), (1.3, 0.3)] {
                for sd in [-1.0, 1.0] {
                    drawEye(inner, shape, x: sd * sp + lx, y: ly, er: er * k, side: sd, color: EYE_GLOW.opacity(a))
                }
            }
        }
        for sd in [-1.0, 1.0] {
            drawEye(inner, shape, x: sd * sp + lx, y: ly, er: er, side: sd, color: mini ? INK : EYE)
        }

        drawAccessory(b, hw: hw, hh: hh)

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

    private func drawAccessory(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        switch skin.accessory {
        case .none: break
        case .kippah:
            drawPayot(ctx, hw: hw, hh: hh)
            drawKippah(ctx, hw: hw, hh: hh)
        case .fez: drawFez(ctx, hw: hw, hh: hh)
        case .nonLa: drawNonLa(ctx, hw: hw, hh: hh)
        case .headphones: drawHeadphones(ctx, hw: hw, hh: hh)
        case .crown: drawCrown(ctx, hw: hw, hh: hh)
        case .beanie: drawBeanie(ctx, hw: hw, hh: hh)
        case .cap: drawCap(ctx, hw: hw, hh: hh)
        }
    }

    /// Skin Turc : grande barbe noire, moustache, et le fez rouge à pompon noir.
    private func drawFez(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let black = Color(hex: "#0C0C12")
        // Barbe : elle part du bas des joues, entoure la bouche par en dessous et dépasse sous la tête, en vagues.
        var beard = Path()
        beard.move(to: CGPoint(x: -hw * 1.0, y: hh * 0.02))
        beard.addCurve(to: CGPoint(x: -hw * 0.5, y: hh * 1.1), control1: CGPoint(x: -hw * 1.1, y: hh * 0.6), control2: CGPoint(x: -hw * 0.85, y: hh * 1.0))
        beard.addQuadCurve(to: CGPoint(x: 0, y: hh * 1.22), control: CGPoint(x: -hw * 0.25, y: hh * 1.24))
        beard.addQuadCurve(to: CGPoint(x: hw * 0.5, y: hh * 1.1), control: CGPoint(x: hw * 0.25, y: hh * 1.24))
        beard.addCurve(to: CGPoint(x: hw * 1.0, y: hh * 0.02), control1: CGPoint(x: hw * 0.85, y: hh * 1.0), control2: CGPoint(x: hw * 1.1, y: hh * 0.6))
        beard.addCurve(to: CGPoint(x: 0, y: hh * 0.66), control1: CGPoint(x: hw * 0.78, y: hh * 0.5), control2: CGPoint(x: hw * 0.32, y: hh * 0.68))
        beard.addCurve(to: CGPoint(x: -hw * 1.0, y: hh * 0.02), control1: CGPoint(x: -hw * 0.32, y: hh * 0.68), control2: CGPoint(x: -hw * 0.78, y: hh * 0.5))
        beard.closeSubpath()
        ctx.fill(beard, with: .color(black))
        // Moustache : deux mèches qui remontent au bout.
        for side in [-1.0, 1.0] {
            var m = Path()
            m.move(to: CGPoint(x: 0, y: hh * 0.24))
            m.addCurve(to: CGPoint(x: side * hw * 0.62, y: hh * 0.2), control1: CGPoint(x: side * hw * 0.2, y: hh * 0.14), control2: CGPoint(x: side * hw * 0.45, y: hh * 0.42))
            m.addQuadCurve(to: CGPoint(x: side * hw * 0.5, y: hh * 0.08), control: CGPoint(x: side * hw * 0.68, y: hh * 0.08))
            m.addCurve(to: CGPoint(x: 0, y: hh * 0.4), control1: CGPoint(x: side * hw * 0.55, y: hh * 0.5), control2: CGPoint(x: side * hw * 0.15, y: hh * 0.46))
            m.closeSubpath()
            ctx.fill(m, with: .color(black))
        }
        // Fez : tronc de cône rouge posé sur le haut de la tête.
        let bottom = -hh * 0.8, top = -hh * 1.8, wb = hw * 0.58, wt = hw * 0.43
        var fez = Path()
        fez.move(to: CGPoint(x: -wb, y: bottom))
        fez.addLine(to: CGPoint(x: -wt, y: top + hh * 0.06))
        fez.addQuadCurve(to: CGPoint(x: wt, y: top + hh * 0.06), control: CGPoint(x: 0, y: top - hh * 0.04))
        fez.addLine(to: CGPoint(x: wb, y: bottom))
        fez.addQuadCurve(to: CGPoint(x: -wb, y: bottom), control: CGPoint(x: 0, y: bottom + hh * 0.12))
        fez.closeSubpath()
        ctx.fill(fez, with: .linearGradient(Gradient(colors: [Color(hex: "#E8303A"), Color(hex: "#B5121D")]),
                                            startPoint: CGPoint(x: -wb, y: top), endPoint: CGPoint(x: wb, y: bottom)))
        guard !mini else { return }
        ctx.fill(Path(ellipseIn: CGRect(cx: 0, cy: top + hh * 0.05, w: wt * 1.9, h: hh * 0.1)), with: .color(Color(hex: "#C81E28")))
        // Pompon : un cordon noir qui part du sommet et pend sur le côté.
        var cord = Path()
        cord.move(to: CGPoint(x: 0, y: top + hh * 0.04))
        cord.addQuadCurve(to: CGPoint(x: wt * 0.92, y: top + hh * 0.2), control: CGPoint(x: wt * 0.75, y: top - hh * 0.02))
        cord.addLine(to: CGPoint(x: wt * 0.98, y: top + hh * 0.45))
        ctx.stroke(cord, with: .color(black), style: StrokeStyle(lineWidth: max(0.6, hh * 0.045), lineCap: .round, lineJoin: .round))
        ctx.fill(Path(roundedRect: CGRect(cx: wt * 0.98, cy: top + hh * 0.53, w: hh * 0.1, h: hh * 0.2), cornerRadius: hh * 0.05), with: .color(black))
    }

    /// Skin Vietnam : le nón lá, chapeau conique rouge à nervures, avec l'étoile jaune.
    private func drawNonLa(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let apex = CGPoint(x: 0, y: -hh * 1.95), w = hw * 1.3, brim = -hh * 0.52, sag = hh * 0.2
        // Ombre du bord sur le front.
        if !mini {
            var shade = Path()
            shade.move(to: CGPoint(x: -hw * 0.95, y: brim + sag * 0.4))
            shade.addQuadCurve(to: CGPoint(x: hw * 0.95, y: brim + sag * 0.4), control: CGPoint(x: 0, y: brim + sag * 2.4))
            shade.addQuadCurve(to: CGPoint(x: -hw * 0.95, y: brim + sag * 0.4), control: CGPoint(x: 0, y: brim + sag * 1.2))
            ctx.fill(shade, with: .color(.black.opacity(0.18)))
        }
        var hat = Path()
        hat.move(to: apex)
        hat.addQuadCurve(to: CGPoint(x: w, y: brim), control: CGPoint(x: w * 0.42, y: -hh * 1.08))  // flancs un peu creusés
        hat.addQuadCurve(to: CGPoint(x: -w, y: brim), control: CGPoint(x: 0, y: brim + sag * 2))   // le bord suit la tête
        hat.addQuadCurve(to: apex, control: CGPoint(x: -w * 0.42, y: -hh * 1.08))
        hat.closeSubpath()
        ctx.fill(hat, with: .linearGradient(Gradient(colors: [Color(hex: "#F0413A"), Color(hex: "#C21F1A")]),
                                            startPoint: CGPoint(x: -w * 0.5, y: apex.y), endPoint: CGPoint(x: w * 0.6, y: brim)))
        guard !mini else {
            ctx.fill(starPath(hh * 0.2, hh * 0.08).offsetBy(dx: 0, dy: -hh * 1.3), with: .color(Color(hex: "#FFE14D")))
            return
        }
        // Nervures de la feuille, du sommet vers le bord.
        var ribs = Path()
        for t in [-0.75, -0.42, -0.14, 0.14, 0.42, 0.75] {
            let x = t * w, y = brim + sag * (1 - t * t) * 1.0
            ribs.move(to: apex)
            ribs.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.stroke(ribs, with: .color(Color(hex: "#8E1410").opacity(0.35)), lineWidth: max(0.5, hh * 0.022))
        // Bord : un liseré plus sombre.
        var rim = Path()
        rim.move(to: CGPoint(x: w, y: brim))
        rim.addQuadCurve(to: CGPoint(x: -w, y: brim), control: CGPoint(x: 0, y: brim + sag * 2))
        ctx.stroke(rim, with: .color(Color(hex: "#9C1712")), style: StrokeStyle(lineWidth: max(0.8, hh * 0.06), lineCap: .round))
        // Reflet sur le flanc gauche.
        var shine = Path()
        shine.move(to: CGPoint(x: apex.x - hw * 0.05, y: apex.y + hh * 0.18))
        shine.addQuadCurve(to: CGPoint(x: -w * 0.62, y: brim - hh * 0.06), control: CGPoint(x: -w * 0.32, y: -hh * 1.12))
        ctx.stroke(shine, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: max(0.6, hh * 0.05), lineCap: .round))
        ctx.fill(starPath(hh * 0.22, hh * 0.09).offsetBy(dx: 0, dy: -hh * 1.3), with: .color(Color(hex: "#FFE14D")))
    }

    /// Casque audio : arceau par-dessus, deux écouteurs sur les côtés.
    private func drawHeadphones(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let dark = Color(hex: "#23262E"), lit = Color(hex: "#3A3F4B")
        var band = Path()
        band.move(to: CGPoint(x: -hw * 0.93, y: -hh * 0.05))
        band.addCurve(to: CGPoint(x: hw * 0.93, y: -hh * 0.05), control1: CGPoint(x: -hw * 0.98, y: -hh * 1.55), control2: CGPoint(x: hw * 0.98, y: -hh * 1.55))
        ctx.stroke(band, with: .color(dark), style: StrokeStyle(lineWidth: max(1, hh * 0.13), lineCap: .round))
        for side in [-1.0, 1.0] {
            let cup = Path(roundedRect: CGRect(cx: side * hw * 0.98, cy: hh * 0.08, w: hw * 0.3, h: hh * 0.62), cornerRadius: hw * 0.13)
            ctx.fill(cup, with: .linearGradient(Gradient(colors: [lit, dark]), startPoint: CGPoint(x: 0, y: -hh * 0.25), endPoint: CGPoint(x: 0, y: hh * 0.4)))
            if !mini {
                ctx.fill(Path(roundedRect: CGRect(cx: side * hw * 1.04, cy: hh * 0.08, w: hw * 0.08, h: hh * 0.3), cornerRadius: hw * 0.04),
                         with: .color(RGB(hex: aura).color(0.9)))
            }
        }
    }

    /// Couronne dorée à cinq pointes, avec des pierres.
    private func drawCrown(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let w = hw * 0.62, base = -hh * 0.78, h = hh * 0.55
        var crown = Path()
        crown.move(to: CGPoint(x: -w, y: base))
        let peaks: [(Double, Double)] = [(-1, 1), (-0.5, 0.55), (0, 1.12), (0.5, 0.55), (1, 1)]
        for (i, pk) in peaks.enumerated() {
            if i > 0 { crown.addLine(to: CGPoint(x: (peaks[i - 1].0 + pk.0) / 2 * w, y: base - h * 0.42)) }
            crown.addLine(to: CGPoint(x: pk.0 * w, y: base - h * pk.1))
        }
        crown.addLine(to: CGPoint(x: w, y: base))
        crown.addQuadCurve(to: CGPoint(x: -w, y: base), control: CGPoint(x: 0, y: base + h * 0.3))
        crown.closeSubpath()
        ctx.fill(crown, with: .linearGradient(Gradient(colors: [Color(hex: "#FFE680"), Color(hex: "#F2A900")]),
                                              startPoint: CGPoint(x: 0, y: base - h), endPoint: CGPoint(x: 0, y: base)))
        guard !mini else { return }
        ctx.stroke(crown, with: .color(Color(hex: "#B9770E").opacity(0.7)), lineWidth: max(0.5, hh * 0.025))
        for (x, c) in [(-0.5, "#FF4D6D"), (0.0, "#38BDF8"), (0.5, "#FF4D6D")] {
            ctx.fill(Path(ellipseIn: CGRect(cx: x * w, cy: base - h * 0.2, w: hh * 0.11, h: hh * 0.11)), with: .color(Color(hex: c)))
        }
    }

    /// Bonnet rouge à revers blanc et pompon.
    private func drawBeanie(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let w = hw * 0.9, base = -hh * 0.5
        var hat = Path()
        hat.move(to: CGPoint(x: -w, y: base))
        hat.addCurve(to: CGPoint(x: w, y: base), control1: CGPoint(x: -w * 0.95, y: -hh * 1.5), control2: CGPoint(x: w * 0.95, y: -hh * 1.5))
        hat.closeSubpath()
        ctx.fill(hat, with: .linearGradient(Gradient(colors: [Color(hex: "#FF6B6B"), Color(hex: "#D93A4A")]),
                                            startPoint: CGPoint(x: 0, y: -hh * 1.2), endPoint: CGPoint(x: 0, y: base)))
        ctx.fill(Path(roundedRect: CGRect(cx: 0, cy: base, w: w * 2.06, h: hh * 0.24), cornerRadius: hh * 0.12), with: .color(Color(hex: "#F4F7FB")))
        ctx.fill(Path(ellipseIn: CGRect(cx: 0, cy: -hh * 1.22, w: hh * 0.32, h: hh * 0.32)), with: .color(Color(hex: "#FFFFFF")))
    }

    /// Casquette sombre, visière vers la droite.
    private func drawCap(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let w = hw * 0.78, base = -hh * 0.62
        var visor = Path()
        visor.move(to: CGPoint(x: w * 0.2, y: base))
        visor.addQuadCurve(to: CGPoint(x: w * 1.55, y: base + hh * 0.06), control: CGPoint(x: w * 1.2, y: base - hh * 0.2))
        visor.addQuadCurve(to: CGPoint(x: w * 0.2, y: base + hh * 0.1), control: CGPoint(x: w, y: base + hh * 0.14))
        visor.closeSubpath()
        ctx.fill(visor, with: .color(Color(hex: "#151A26")))
        var dome = Path()
        dome.move(to: CGPoint(x: -w, y: base))
        dome.addCurve(to: CGPoint(x: w, y: base), control1: CGPoint(x: -w * 0.95, y: -hh * 1.45), control2: CGPoint(x: w * 0.95, y: -hh * 1.45))
        dome.closeSubpath()
        ctx.fill(dome, with: .linearGradient(Gradient(colors: [Color(hex: "#2E3A55"), Color(hex: "#1B2235")]),
                                             startPoint: CGPoint(x: 0, y: -hh * 1.2), endPoint: CGPoint(x: 0, y: base)))
        if !mini { ctx.fill(Path(ellipseIn: CGRect(cx: 0, cy: -hh * 1.12, w: hh * 0.12, h: hh * 0.12)), with: .color(Color(hex: "#2E3A55"))) }
    }

    /// Papillotes : deux boucles sombres qui ondulent le long des côtés (pas sur les mini, trop fines).
    private func drawPayot(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        guard !mini else { return }
        let sway = sin(now * 1.6) * 0.04  // elles bougent un peu avec le temps
        for side in [-1.0, 1.0] {
            var p = Path()
            for i in 0...40 {
                let t = Double(i) / 40, y = lerp(-0.42, 0.98, t) * hh
                let x = side * hw * (0.99 + 0.035 * t + sin(t * .pi * 3.4 + side * 0.4) * (0.075 + sway * t))
                i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(p, with: .color(Color(hex: "#24285E")), style: StrokeStyle(lineWidth: max(1, hh * 0.09), lineCap: .round, lineJoin: .round))
        }
    }

    /// Kippa blanche posée sur le haut du galet, étoile de David bleue au milieu.
    private func drawKippah(_ ctx: GraphicsContext, hw: Double, hh: Double) {
        let kw = hw * 0.5, kh = hh * 0.44, kb = -hh * 0.8
        var cap = Path()
        cap.move(to: CGPoint(x: -kw, y: kb))
        cap.addCurve(to: CGPoint(x: kw, y: kb), control1: CGPoint(x: -kw * 0.95, y: kb - kh * 1.32), control2: CGPoint(x: kw * 0.95, y: kb - kh * 1.32))
        cap.addQuadCurve(to: CGPoint(x: -kw, y: kb), control: CGPoint(x: 0, y: kb + kh * 0.28))  // le bord suit la tête
        cap.closeSubpath()
        ctx.fill(cap, with: .linearGradient(Gradient(colors: [Color(hex: "#FFFFFF"), Color(hex: "#DCEBFA")]),
                                            startPoint: CGPoint(x: 0, y: kb - kh), endPoint: CGPoint(x: 0, y: kb)))
        guard hh > 6 else { return }  // trop petit pour l'étoile
        let r = kh * 0.34, cy = kb - kh * 0.5
        var star = Path()
        for base in [-Double.pi / 2, Double.pi / 2] {  // deux triangles, pointe en haut puis en bas
            for k in 0..<3 {
                let a = base + Double(k) * 2 * .pi / 3
                let pt = CGPoint(x: cos(a) * r, y: cy + sin(a) * r)
                k == 0 ? star.move(to: pt) : star.addLine(to: pt)
            }
            star.closeSubpath()
        }
        ctx.stroke(star, with: .color(Color(hex: "#2F5BD3")), style: StrokeStyle(lineWidth: max(0.6, r * 0.22), lineJoin: .round))
    }

    /// Couleur de la lueur : celle choisie, sinon celle du skin.
    private var aura: String { bodyColor == nil ? (tint ?? skin.aura) : skin.aura }

    /// Haut et bas du corps : le galet néon, ou la couleur de la session pour les mini.
    private var palette: (RGB, RGB) {
        if bodyColor == nil, let tint {  // une couleur choisie : plus claire en haut, plus profonde en bas
            let c = RGB(hex: tint)
            return (c.mix(RGB(255, 255, 255), 0.38), c.mix(RGB(0, 0, 0), 0.22))
        }
        guard let c = bodyColor else { return (RGB(hex: skin.top), RGB(hex: skin.bottom)) }
        return (c.mix(RGB(255, 255, 255), 0.3), c.mix(RGB(0, 0, 0), 0.12))
    }

    /// Yeux néon : ●● ouverts, —— fermés, ^^ contents, OO surpris, ó ò inquiets (ò ó fâchés), ‾● concentrés.
    private func drawEye(_ ctx: GraphicsContext, _ shape: Eye, x: Double, y: Double, er: Double, side: Double, color: Color) {
        let ink = GraphicsContext.Shading.color(color)
        let line = StrokeStyle(lineWidth: er * 0.46, lineCap: .round, lineJoin: .round)
        func arc(_ cy: Double, _ r: Double, _ a0: Double, _ a1: Double, _ w: Double) {
            var p = Path()
            p.addArc(center: CGPoint(x: x, y: cy), radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        /// Rond qui s'aplatit en trait quand l'œil se ferme (clignement).
        func dot(_ r: Double) {
            let h = max(er * 0.46, 2 * r * s.open), w = 2 * r * (h < r ? 1.15 : 1)
            ctx.fill(Path(roundedRect: CGRect(cx: x, cy: y, w: w, h: h), cornerRadius: min(w, h) / 2), with: ink)
        }
        /// Sourcil incliné : `inner` > 0 relève le côté du nez (inquiet), < 0 l'abaisse (fâché).
        func brow(_ inner: Double) {
            var p = Path()
            p.move(to: CGPoint(x: x - side * er * 1.15, y: y - er * 1.75 - inner * er * 0.35))  // côté du nez
            p.addLine(to: CGPoint(x: x + side * er * 0.95, y: y - er * 1.75 + inner * er * 0.35))
            ctx.stroke(p, with: ink, style: line)
        }
        switch shape {
        case .dot:
            dot(er)
        case .wide:
            ctx.stroke(Path(ellipseIn: CGRect(cx: x, cy: y, w: er * 2.3, h: er * 2.3 * max(0.2, s.open))), with: ink, style: line)
        case .happy:
            var p = Path()
            p.move(to: CGPoint(x: x - er * 1.05, y: y + er * 0.45))
            p.addLine(to: CGPoint(x: x, y: y - er * 0.55))
            p.addLine(to: CGPoint(x: x + er * 1.05, y: y + er * 0.45))
            ctx.stroke(p, with: ink, style: line)
        case .content:
            arc(y - er * 0.5, er * 1.15, .pi * 0.15, .pi * 0.85, er * 0.46)
        case .closed:
            ctx.fill(Path(roundedRect: CGRect(cx: x, cy: y, w: er * 2.4, h: er * 0.46), cornerRadius: er * 0.23), with: ink)
        case .flat:
            dot(er * 0.95)
            brow(1)
        case .line:
            dot(er * 0.85)
            brow(-1)
        case .focus:  // paupière plate, la pupille glisse dessous sur le côté
            let r = er * 0.78
            ctx.fill(Path(ellipseIn: CGRect(cx: x + er * 0.42, cy: y + er * 0.12, w: 2 * r, h: 2 * r * max(0.3, s.open))), with: ink)
            ctx.fill(Path(roundedRect: CGRect(cx: x - er * 0.05, cy: y - er * 0.42, w: er * 2.5, h: er * 0.46), cornerRadius: er * 0.23), with: ink)
        case .tired:
            ctx.fill(Path(roundedRect: CGRect(x: x - er, y: y - er * 0.1, width: 2 * er, height: er * 1.1), cornerRadius: er * 0.55), with: ink)
            ctx.fill(Path(roundedRect: CGRect(cx: x, cy: y - er * 0.2, w: er * 2.6, h: er * 0.46), cornerRadius: er * 0.23), with: ink)
        case .spiral:
            var p = Path()
            var a = 0.0
            while a < 4.4 * .pi {
                let r = er * 0.12 + a * er * 0.1, aa = a + now * 9 * side
                let pt = CGPoint(x: x + cos(aa) * r, y: y + sin(aa) * r)
                a == 0 ? p.move(to: pt) : p.addLine(to: pt)
                a += 0.2
            }
            ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: er * 0.36, lineCap: .round))
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
            if side < 0 { drawEye(ctx, .dot, x: x, y: y, er: er, side: side, color: color) }
            else { drawEye(ctx, .happy, x: x, y: y, er: er, side: side, color: color) }
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
