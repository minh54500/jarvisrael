import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Onglet Étagère : fichiers gardés, historique des copies, dépôt et conversion de fichiers, AirDrop.

/// Étagère : les fichiers gardés (glisser = déposer ailleurs, clic = copier) ou l'historique
/// du presse-papiers (clic = recopier).
struct ShelfPanel: View {
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
                    if !clips && !store.shelf.isEmpty {
                        Button { airDrop(store.shelf) } label: { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11.5, weight: .semibold)) }
                            .buttonStyle(IconButton())
                            .help("Envoyer les fichiers de l'étagère par AirDrop")
                            .accessibilityLabel("AirDrop")
                    }
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

/// AirDrop : la fenêtre de macOS pour choisir l'appareil.
@MainActor func airDrop(_ urls: [URL]) {
    guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
    NSApp.activate(ignoringOtherApps: true)
    service.perform(withItems: urls)
}

/// Un élément copié : texte (3 lignes) ou image. Clic = recopier ; glisser = déposer ailleurs.
struct ClipItem: View {
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

struct ShelfItem: View {
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
            Button("Envoyer par AirDrop") { airDrop([url]) }
            if TextAI.canSummarize(url) { Button("Résumer avec l'IA") { TextAI.shared.summarize(url) } }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Retirer de l'étagère") { store.unshelve(url) }
        }
        .help(url.path)
    }
}

/// Fichiers glissés vers l'encoche : à gauche on les garde (étagère), à droite on les convertit.
struct UploadPanel: View {
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

struct DropZone: View {
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
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
            DroppedFiles.load(providers) { onFiles($0) }
            return true
        }
    }
}

/// Ce qu'on lâche sur l'encoche, en fichiers qui restent. La vignette d'une capture d'écran (et d'autres
/// apps) ne donne qu'un fichier temporaire, effacé juste après le dépôt, ou seulement l'image : on en
/// garde une copie dans ~/Library/Application Support/Encoche/Étagère.
enum DroppedFiles {
    static let folder = Bridge.folder.appendingPathComponent("Étagère")

    static func load(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()
        func found(_ i: Int, _ url: URL?) {
            lock.lock(); urls[i] = url; lock.unlock()
            group.leave()
        }
        for (i, p) in providers.enumerated() {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, let kept = keep(url) { return found(i, kept) }
                    image(p) { found(i, $0) }  // pas de fichier lisible : l'image elle-même
                }
            } else {
                image(p) { found(i, $0) }
            }
        }
        group.notify(queue: .main) {
            let list = urls.compactMap { $0 }
            log(providers, list)
            done(list)
        }
    }

    /// Le fichier tel quel, ou sa copie s'il est dans un dossier temporaire ; nil s'il n'existe déjà plus.
    private static func keep(_ dropped: URL) -> URL? {
        let url = (dropped as NSURL).filePathURL ?? dropped  // les liens « /.file/id=… » du Finder
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let path = url.resolvingSymlinksInPath().path
        let temporary = path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") || path.hasPrefix("/private/tmp/")
            || path.contains("/TemporaryItems/") || path.contains("/Containers/com.apple.screencaptureui/")
        return temporary ? copy(url, name: url.lastPathComponent) : url
    }

    /// L'image transportée par le glisser (une vignette, une image de page web…), écrite dans notre dossier.
    private static func image(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
        guard let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false }) else { return done(nil) }
        _ = p.loadFileRepresentation(forTypeIdentifier: type) { tmp, _ in
            guard let tmp else { return done(nil) }
            let ext = UTType(type)?.preferredFilenameExtension ?? tmp.pathExtension
            let base = p.suggestedName ?? "Image \(Date().formatted(.dateTime.year().month().day().hour().minute().second()))"
            done(copy(tmp, name: (base as NSString).pathExtension.isEmpty ? base + "." + ext : base))
        }
    }

    /// Retirés de l'étagère : nos copies s'en vont (les vrais fichiers, eux, ne sont jamais touchés).
    static func forget(_ urls: [URL]) {
        for u in urls where u.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            try? FileManager.default.removeItem(at: u)
        }
    }

    private static func copy(_ src: URL, name: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        var dst = folder.appendingPathComponent(clean), n = 2
        while fm.fileExists(atPath: dst.path) {  // même nom déjà gardé : « nom 2.png »
            let stem = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
            dst = folder.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return (try? fm.copyItem(at: src, to: dst)) != nil ? dst : nil
    }

    /// Une ligne par dépôt dans drop.log (types reçus, fichiers gardés) : pour comprendre un dépôt qui rate.
    private static func log(_ providers: [NSItemProvider], _ kept: [URL]) {
        let line = "\(Date()) types=\(providers.map(\.registeredTypeIdentifiers)) gardés=\(kept.map(\.path))\n"
        let file = Bridge.folder.appendingPathComponent("drop.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size < 100_000, let h = try? FileHandle(forWritingTo: file) {  // au-delà de 100 Ko, on repart de zéro
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }
}

struct ChoosePanel: View {
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

struct ConvertingPanel: View {
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

struct ResultPanel: View {
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
