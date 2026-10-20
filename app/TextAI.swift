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
        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        source = String((text ?? "").prefix(40_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        Store.shared.openTool(.text)
        if source.isEmpty { error = "Je n'arrive pas à lire le texte de ce fichier." } else { run(.summary) }
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
            let saved = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(text, forType: .string)
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            Self.press(app.processIdentifier, 9, .maskCommand)  // ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
            }
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
        let saved = pb.string(forType: .string), before = pb.changeCount
        press(app.processIdentifier, 8, .maskCommand)  // ⌘C
        let end = Date().addingTimeInterval(0.6)
        while pb.changeCount == before && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        return text
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
