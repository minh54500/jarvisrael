import AppKit
import ApplicationServices
import PDFKit

/// IA sur le texte : tu sélectionnes un texte dans n'importe quelle app, ⌥⇧R, et Claude le corrige,
/// le reformule, le raccourcit, le traduit… Le résultat remplace la sélection ou se copie. Marche aussi
/// sur un PDF ou un texte de l'étagère (« Résumer avec l'IA »).
@MainActor
final class TextAI: ObservableObject {
    static let shared = TextAI()

    enum Action: String, CaseIterable, Identifiable {
        case fix = "Corriger", rephrase = "Reformuler", shorter = "Plus court", pro = "Plus pro",
             english = "En anglais", french = "En français", summary = "Résumer"
        var id: String { rawValue }

        var instruction: String {
            switch self {
            case .fix: "Corrige l'orthographe, la grammaire et la ponctuation, sans changer le style ni le sens."
            case .rephrase: "Reformule ce texte de façon plus claire et naturelle, même langue, même longueur environ."
            case .shorter: "Raccourcis ce texte de moitié environ, en gardant l'essentiel, même langue."
            case .pro: "Réécris ce texte sur un ton professionnel et courtois, même langue."
            case .english: "Traduis ce texte en anglais naturel."
            case .french: "Traduis ce texte en français naturel."
            case .summary: "Résume ce texte en français en quelques points courts (tirets), l'essentiel seulement."
            }
        }
    }

    @Published private(set) var source = ""
    @Published private(set) var origin = ""      // d'où vient le texte (app ou fichier)
    @Published private(set) var result = ""
    @Published private(set) var busy: Action?
    @Published private(set) var error: String?
    private var target: NSRunningApplication?   // l'app où remplacer la sélection
    private var fromFile = false

    var canReplace: Bool { !fromFile && target != nil && !result.isEmpty }

    /// ⌥⇧R : on prend la sélection de l'app de devant, et l'encoche ouvre « Texte IA ».
    func grabSelection() {
        let app = NSWorkspace.shared.frontmostApplication
        guard app != NSRunningApplication.current else { return Store.shared.openTool(.text) }
        target = app
        fromFile = false
        origin = app?.localizedName ?? ""
        result = ""
        error = nil
        let text = Self.selectedTextAX() ?? Self.selectedTextByCopy(app)
        source = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source.isEmpty { error = "Sélectionne d'abord un texte dans une app, puis ⌥⇧R." }
        Store.shared.openTool(.text)
    }

    /// Un fichier de l'étagère : PDF (son texte) ou fichier texte, résumé tout de suite.
    func summarize(_ url: URL) {
        target = nil
        fromFile = true
        origin = url.lastPathComponent
        result = ""
        error = nil
        source = ""
        busy = .summary
        Store.shared.openTool(.text)
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.read(url, limit: 40_000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ai = TextAI.shared
                    ai.busy = nil
                    ai.source = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if ai.source.isEmpty { ai.error = "Je n'arrive pas à lire le texte de ce fichier." } else { ai.run(.summary) }
                }
            }
        }
    }

    /// Le texte d'un fichier, sans tout charger : un PDF page par page, un texte par le début.
    nonisolated private static func read(_ url: URL, limit: Int) -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { return "" }
            var out = ""
            for i in 0..<doc.pageCount where out.count < limit { out += (doc.page(at: i)?.string ?? "") + "\n" }
            return String(out.prefix(limit))
        }
        guard let h = try? FileHandle(forReadingFrom: url), let data = try? h.read(upToCount: limit * 4) else { return "" }
        try? h.close()
        return String(String(decoding: data, as: UTF8.self).prefix(limit))
    }

    static func canSummarize(_ url: URL) -> Bool { ["pdf", "txt", "md", "markdown", "csv", "json", "html"].contains(url.pathExtension.lowercased()) }

    func run(_ a: Action) {
        guard !source.isEmpty, busy == nil else { return }
        busy = a
        error = nil
        let system = "Tu es un outil d'écriture intégré à une app Mac. " + a.instruction
            + " Réponds uniquement par le texte demandé, sans introduction, sans guillemets, sans commentaire."
        Claude.run(prompt: source, system: system, model: a == .summary ? "sonnet" : "haiku") { lines in
            let text = lines.first ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ai = TextAI.shared
                    ai.busy = nil
                    if text.isEmpty { ai.error = "Claude n'a pas répondu. Claude Code est-il installé et connecté ?" } else { ai.result = text }
                    Sound.shared.play(text.isEmpty ? "error" : "pop")
                }
            }
        }
    }

    func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(result, forType: .string)
        Store.shared.say("Copié ✓ colle-le où tu veux (⌘V)", ok: true)
    }

    /// Remplace la sélection dans l'app d'origine : directement si elle le permet, sinon par un collage.
    func replace() {
        guard canReplace, let app = target else { return }
        let text = result
        Store.shared.collapse()
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if Self.replaceSelectionAX(text) { return Sound.shared.play("approve") }
            let pb = NSPasteboard.general
            let saved = Self.saveClipboard()
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let mine = pb.changeCount
            Self.press(app.processIdentifier, 9, .maskCommand)  // ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Self.restoreClipboard(saved, ifStill: mine) }
            Sound.shared.play("approve")
        }
    }

    // MARK: Sélection (Accessibilité)

    private static func focused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let e = v, CFGetTypeID(e) == AXUIElementGetTypeID() else { return nil }
        return (e as! AXUIElement)
    }

    private static func selectedTextAX() -> String? {
        guard let e = focused() else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextAttribute as CFString, &v) == .success,
              let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func replaceSelectionAX(_ text: String) -> Bool {
        guard let e = focused(), selectedTextAX() != nil else { return false }
        return AXUIElementSetAttributeValue(e, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Les apps qui ne disent pas leur sélection (navigateurs…) : un ⌘C, puis on rend le presse-papiers.
    private static func selectedTextByCopy(_ app: NSRunningApplication?) -> String? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let pb = NSPasteboard.general
        let saved = saveClipboard(), before = pb.changeCount
        press(app.processIdentifier, 8, .maskCommand)  // ⌘C
        let end = Date().addingTimeInterval(1.0)
        while pb.changeCount == before && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        restoreClipboard(saved, ifStill: pb.changeCount)
        return text
    }

    /// Copie complète du presse-papiers : chaque élément avec tous ses types (image, fichier, texte mis en forme…).
    private static func saveClipboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    /// Rend le presse-papiers d'avant, sauf si quelqu'un a copié autre chose entre-temps.
    private static func restoreClipboard(_ items: [NSPasteboardItem], ifStill change: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == change else { return }
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private static func press(_ pid: pid_t, _ key: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }
}
