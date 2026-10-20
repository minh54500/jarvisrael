// Génère l'icône de l'app (le Mochi sur fond noir) : icon <dossier.iconset>
import AppKit
import SwiftUI

@MainActor func render(size: Int) -> Data {
    let mochi = Mochi(now: 0)
    mochi.update(0.016)
    let s = Double(size)
    let view = Canvas { ctx, _ in
        let inset = s * 0.1
        let tile = Path(roundedRect: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), cornerRadius: s * 0.18, style: .continuous)
        ctx.fill(tile, with: .linearGradient(Gradient(colors: [Color(hex: "#1B1D22"), Color(hex: "#050506")]),
                                             startPoint: CGPoint(x: 0, y: inset), endPoint: CGPoint(x: 0, y: s - inset)))
        mochi.draw(ctx, cx: s / 2, cy: s * 0.53, hb: s * 0.36)
    }
    .frame(width: s, height: s)
    let r = ImageRenderer(content: view)
    let rep = NSBitmapImageRep(data: r.nsImage!.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

@main struct Icon {
    static func main() {
        MainActor.assumeIsolated {
            let out = URL(fileURLWithPath: CommandLine.arguments[1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for size in [16, 32, 128, 256, 512] {
                try! render(size: size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
                try! render(size: size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
            }
        }
    }
}
