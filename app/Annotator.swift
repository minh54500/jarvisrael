import AppKit
import SwiftUI

/// Annoter une capture avant de l'envoyer à Claude : stylo, flèche, cadre, quatre couleurs, annuler.
/// L'image annotée remplace la capture ; « Envoyer » l'ajoute au message, « Étagère » la garde seulement.
@MainActor
enum Annotator {
    private static var window: NSWindow?

    /// `done` reçoit l'image (annotée ou non) et si on l'envoie à Claude ; nil si on abandonne.
    static func open(_ url: URL, done: @escaping (URL?, Bool) -> Void) {
        guard let image = NSImage(contentsOf: url) else { return done(url, true) }
        window?.close()  // une seule fenêtre à la fois : l'ancienne capture reste dans le dossier des captures
        let size = image.size, maxW = 980.0, maxH = 640.0
        let k = min(1, maxW / size.width, maxH / size.height)
        let canvas = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(canvas.width, 560), height: canvas.height + 64),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Annoter la capture"
        w.isReleasedWhenClosed = false
        var finished = false
        w.contentView = NSHostingView(rootView: AnnotatorView(image: image, canvas: canvas) { [weak w] strokes, send in
            guard !finished else { return }  // un seul envoi par fenêtre
            finished = true
            w?.close()
            if window === w { window = nil }
            guard let strokes else { return done(nil, false) }
            done(strokes.isEmpty ? url : (render(image, strokes) ?? url), send)
        })
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Les traits (en coordonnées 0…1) dessinés sur l'image en pleine résolution.
    private static func render(_ image: NSImage, _ strokes: [Stroke]) -> URL? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)  // origine en haut à gauche, comme à l'écran
        let scale = Double(w)
        for s in strokes {
            let path = s.path(in: CGSize(width: w, height: h))
            ctx.setStrokeColor(NSColor(s.color).cgColor)
            ctx.setLineWidth(s.width * scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dst = Bridge.folder.appendingPathComponent("Captures/annotee-\(Int(Date().timeIntervalSince1970)).png")
        return (try? png.write(to: dst)) != nil ? dst : nil
    }
}

struct Stroke: Identifiable {
    enum Tool { case pen, arrow, box }
    let id = UUID()
    var tool: Tool
    var color: Color
    var width: Double        // en part de la largeur de l'image
    var points: [CGPoint]    // 0…1

    func path(in size: CGSize) -> Path {
        let pts = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        var p = Path()
        guard let a = pts.first, let b = pts.last else { return p }
        switch tool {
        case .pen:
            p.move(to: a)
            for q in pts.dropFirst() { p.addLine(to: q) }
        case .box:
            p.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .arrow:
            p.move(to: a)
            p.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x), head = max(10, width * size.width * 4.5)
            for side in [-1.0, 1.0] {
                p.move(to: b)
                p.addLine(to: CGPoint(x: b.x - head * cos(angle + side * 0.45), y: b.y - head * sin(angle + side * 0.45)))
            }
        }
        return p
    }
}

private struct AnnotatorView: View {
    let image: NSImage
    let canvas: CGSize
    let finish: ([Stroke]?, Bool) -> Void
    @State private var strokes: [Stroke] = []
    @State private var current: Stroke?
    @State private var tool = Stroke.Tool.arrow
    @State private var color = Color(hex: "#FF3B30")

    private let colors = ["#FF3B30", "#FFCC00", "#0A84FF", "#FFFFFF"]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Image(nsImage: image).resizable().frame(width: canvas.width, height: canvas.height)
                Canvas { ctx, size in
                    for s in strokes + (current.map { [$0] } ?? []) {
                        ctx.stroke(s.path(in: size), with: .color(s.color),
                                   style: StrokeStyle(lineWidth: s.width * size.width, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let p = CGPoint(x: g.location.x / canvas.width, y: g.location.y / canvas.height)
                    if current == nil { current = Stroke(tool: tool, color: color, width: tool == .pen ? 0.004 : 0.003, points: [p]) }
                    if tool == .pen { current?.points.append(p) } else { current?.points = [current!.points[0], p] }
                }.onEnded { _ in
                    if let c = current { strokes.append(c) }
                    current = nil
                })
            }
            .frame(maxWidth: .infinity)
            .background(Color.black)
            HStack(spacing: 10) {
                Picker("", selection: $tool) {
                    Image(systemName: "arrow.up.right").tag(Stroke.Tool.arrow)
                    Image(systemName: "rectangle").tag(Stroke.Tool.box)
                    Image(systemName: "pencil.tip").tag(Stroke.Tool.pen)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .labelsHidden()
                ForEach(colors, id: \.self) { hex in
                    Button { color = Color(hex: hex) } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(color == Color(hex: hex) ? Color.primary : .gray.opacity(0.4), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
                Button { _ = strokes.popLast() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(strokes.isEmpty).keyboardShortcut("z", modifiers: .command).help("Annuler (⌘Z)")
                Spacer()
                Button("Annuler") { finish(nil, false) }.keyboardShortcut(.cancelAction)
                Button("Garder dans l'étagère") { finish(strokes, false) }
                Button("Envoyer à Claude") { finish(strokes, true) }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 64)
        }
    }
}
