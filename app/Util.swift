import SwiftUI

func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a), 0, 1) }

enum Ease {
    static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func cubicIn(_ t: Double) -> Double { t * t * t }
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func back(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
    static func lin(_ t: Double) -> Double { t }
}

struct RGB {
    var r, g, b: Double  // 0…255

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: String) {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255))
    }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(lerp(r, o.r, t), lerp(g, o.g, t), lerp(b, o.b, t)) }
    func color(_ a: Double = 1) -> Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
}

extension Color {
    init(hex: String, _ a: Double = 1) { self = RGB(hex: hex).color(a) }
}

/// Ressort amorti (même modèle que les prototypes de Louis), intégré à pas fixe.
struct Spring {
    var v: Double
    var vel = 0.0
    var response: Double
    var damping: Double

    init(_ v: Double, response: Double = 0.42, damping: Double = 0.8) {
        self.v = v; self.response = response; self.damping = damping
    }
    mutating func step(to target: Double, dt: Double) {
        let k = pow(2 * .pi / response, 2), c = 2 * damping * sqrt(k)
        var left = dt
        while left > 0 {  // sous-pas pour rester stable même si une image saute
            let h = min(left, 1.0 / 240)
            vel += (k * (target - v) - c * vel) * h
            v += vel * h
            left -= h
        }
    }
}

/// Superellipse : la forme du Mochi (exposant 3,2 = « pain de riz » de Louis).
func superellipse(_ hw: Double, _ hh: Double, n: Double = 3.2, steps: Int = 72) -> Path {
    var p = Path()
    for i in 0...steps {
        let a = Double(i) / Double(steps) * 2 * .pi, ca = cos(a), sa = sin(a)
        let x = hw * (ca < 0 ? -1 : 1) * pow(abs(ca), 2 / n)
        let y = hh * (sa < 0 ? -1 : 1) * pow(abs(sa), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// Galet : superellipse un peu plus large en haut qu'en bas, `hw`/`hh` = demi-largeur/demi-hauteur.
func pebblePath(_ hw: Double, _ hh: Double, steps: Int = 96) -> Path {
    var p = Path()
    for i in 0...steps {
        let a = Double(i) / Double(steps) * 2 * .pi, ca = cos(a), sa = sin(a)
        let y = hh * (sa < 0 ? -1 : 1) * pow(abs(sa), 2 / 2.4)
        let x = hw * (ca < 0 ? -1 : 1) * pow(abs(ca), 2 / 2.4) * (1 - 0.07 * y / hh)  // haut plus large
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func heartPath(_ s: Double) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 0, y: s * 0.38))
    p.addCurve(to: CGPoint(x: 0, y: -s * 0.38), control1: CGPoint(x: -s * 1.05, y: -s * 0.15), control2: CGPoint(x: -s * 0.5, y: -s * 0.95))
    p.addCurve(to: CGPoint(x: 0, y: s * 0.38), control1: CGPoint(x: s * 0.5, y: -s * 0.95), control2: CGPoint(x: s * 1.05, y: -s * 0.15))
    p.closeSubpath()
    return p
}

func starPath(_ ro: Double, _ ri: Double) -> Path {
    var p = Path()
    for i in 0..<10 {
        let r = i % 2 == 1 ? ri : ro, a = -Double.pi / 2 + Double(i) * .pi / 5
        let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

extension CGRect {
    init(cx: Double, cy: Double, w: Double, h: Double) {
        self.init(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
