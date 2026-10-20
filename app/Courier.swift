import AppKit
import ApplicationServices

// Envoie un message tapé dans l'encoche à une session Claude Code de VS Code, comme si on l'avait
// tapé soi-même : la fenêtre et l'onglet de la session passent devant, le texte est collé dans le
// champ « Message input » de Claude, puis envoyé. Chaque étape est vérifiée avant la suivante :
// on ne colle que dans le champ de Claude, jamais par-dessus un brouillon, et on n'envoie que si
// le texte est bien arrivé. Demande l'autorisation « Accessibilité » de macOS.
//
// Les sessions lancées dans un terminal ne reçoivent jamais de frappes à l'aveugle (un mauvais
// onglet pourrait exécuter le texte comme une commande) : le message est copié, à coller soi-même.

enum Courier {
    enum Outcome { case sent, copied, needsPermission, failed(String) }

    private static let vscode = "com.microsoft.VSCode"
    private static let queue = DispatchQueue(label: "encoche.courier")

    /// Lien de l'extension Claude Code qui affiche l'onglet de la session (sans rien y écrire).
    static func sessionLink(_ s: Session) -> URL? {
        guard s.entrypoint == "claude-vscode", UUID(uuidString: s.id) != nil else { return nil }
        return URL(string: "vscode://anthropic.claude-code/open?session=\(s.id)")
    }

    @MainActor
    static func send(_ text: String, to s: Session, done: @escaping @MainActor (Outcome) -> Void) {
        if s.termProgram == "Apple_Terminal" && !s.tty.isEmpty { return sendToTerminal(text, tty: s.tty, done: done) }
        guard let link = sessionLink(s) else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            Store.shared.openSession(s)
            return done(.copied)
        }
        guard AXIsProcessTrusted() else {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            return done(.needsPermission)
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let cwd = s.cwd
        queue.async {
            let outcome = deliver(text, cwd: cwd, link: link)
            DispatchQueue.main.async {
                // Envoyé : on revient là où on était (si ce n'était pas déjà VS Code).
                if case .sent = outcome, let previous, let url = previous.bundleURL,
                   previous.bundleIdentifier != vscode, previous != NSRunningApplication.current {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
                MainActor.assumeIsolated { done(outcome) }
            }
        }
    }

    // MARK: Terminal d'Apple

    private static let terminal = "com.apple.Terminal"

    /// Session dans le Terminal : on vérifie que Claude est bien au premier plan dans son onglet (sinon le
    /// texte partirait dans le shell comme une commande), on amène l'onglet devant, on colle et on envoie.
    @MainActor
    private static func sendToTerminal(_ text: String, tty: String, done: @escaping @MainActor (Outcome) -> Void) {
        guard AXIsProcessTrusted() else {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            return done(.needsPermission)
        }
        let previous = NSWorkspace.shared.frontmostApplication
        queue.async {
            let outcome = deliverToTerminal(text, tty: tty)
            DispatchQueue.main.async {
                if case .sent = outcome, let previous, let url = previous.bundleURL,
                   previous.bundleIdentifier != terminal, previous != NSRunningApplication.current {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
                MainActor.assumeIsolated { done(outcome) }
            }
        }
    }

    private static func deliverToTerminal(_ text: String, tty: String) -> Outcome {
        guard claudeInFront(tty) else { return .failed("Claude ne tourne plus dans cet onglet du Terminal : rien n'a été envoyé.") }
        switch focusTerminalTab(tty) {
        case "ok": break
        case "denied": return .failed("Autorise Encoche à piloter le Terminal : Réglages Système → Confidentialité → Automatisation.")
        default: return .failed("Je ne trouve plus l'onglet de cette session dans le Terminal.")
        }
        guard wait(3, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal }),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: terminal).first
        else { return .failed("Le Terminal n'est pas passé devant.") }
        Thread.sleep(forTimeInterval: 0.25)
        let saved = DispatchQueue.main.sync { Clipboard.put(text) }
        defer {
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.sync { Clipboard.restore(saved) }
        }
        press(app.processIdentifier, 9, .maskCommand)  // ⌘V (collage « entre crochets » : les retours à la ligne restent dans le message)
        Thread.sleep(forTimeInterval: 0.3)
        press(app.processIdentifier, 36)  // Entrée
        return .sent
    }

    /// Le programme au premier plan de ce terminal est-il Claude ? (« + » dans l'état = premier plan.)
    private static func claudeInFront(_ tty: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-t", tty.replacingOccurrences(of: "/dev/", with: ""), "-o", "stat=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        p.waitUntilExit()
        return lines.contains { line in
            let cols = line.split(separator: " ", maxSplits: 1)
            return cols.count == 2 && cols[0].contains("+") && cols[1].lowercased().contains("claude")
        }
    }

    /// Met l'onglet de ce terminal devant (AppleScript). « ok », « notfound » ou « denied ».
    @discardableResult
    static func focusTerminalTab(_ tty: String) -> String {
        let script = """
            tell application id "\(terminal)"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "notfound"
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return "notfound" }
        let result = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if error.contains("-1743") { return "denied" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Étapes (file de fond : l'animation de l'encoche n'est jamais bloquée)

    private static func deliver(_ text: String, cwd: String, link: URL) -> Outcome {
        let ws = NSWorkspace.shared
        guard let appURL = ws.urlForApplication(withBundleIdentifier: vscode) else { return .failed("VS Code est introuvable.") }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: vscode).isEmpty

        // 1. La fenêtre du dossier de la session passe devant, puis l'onglet de la session.
        ws.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        guard wait(wasRunning ? 3 : 15, { ws.frontmostApplication?.bundleIdentifier == vscode }),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: vscode).first
        else { return .failed("VS Code n'est pas passé devant.") }
        Thread.sleep(forTimeInterval: 0.35)
        ws.open(link)
        Thread.sleep(forTimeInterval: 0.8)

        // 2. Le champ de Claude qui a le focus dans cet onglet.
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1)
        _ = string(ax, kAXRoleAttribute)  // réveille l'arbre d'accessibilité de VS Code
        var found: AXUIElement?
        _ = wait(4) { found = input(in: ax); return found != nil }
        guard let field = found else {
            return .failed("Je ne trouve pas le champ de Claude. Si VS Code demande d'ouvrir le lien, accepte (« ne plus demander »), puis renvoie.")
        }
        // (Un champ vide renvoie son texte d'invite, « Queue another message… » : on ne peut pas
        // savoir avant de coller s'il y a un brouillon. On le vérifie juste après, voir plus bas.)
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard wait(1, { (attribute(field, kAXFocusedAttribute) as? Bool) == true }) else {
            return .failed("Le champ de Claude n'a pas pris le focus.")
        }

        // 3. Coller, vérifier, envoyer.
        let saved = DispatchQueue.main.sync { Clipboard.put(text) }
        defer {
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.sync { Clipboard.restore(saved) }
        }
        press(app.processIdentifier, 9, .maskCommand)  // ⌘V
        let mine = normalized(text)
        guard wait(1.5, { normalized(string(field, kAXValueAttribute)).contains(mine) }) else {
            return .failed("Le texte n'est pas arrivé dans Claude : rien n'a été envoyé.")
        }
        // Le champ doit contenir exactement notre message. Sinon, il y avait un brouillon :
        // on annule le collage et on n'envoie rien.
        if normalized(string(field, kAXValueAttribute)) != mine {
            press(app.processIdentifier, 6, .maskCommand)  // ⌘Z
            let undone = wait(1, { !normalized(string(field, kAXValueAttribute)).contains(mine) })
            return .failed(undone ? "Il y a déjà un brouillon dans Claude : rien n'a été envoyé."
                                  : "Il y avait un brouillon dans Claude : ton message a été ajouté à la suite, rien n'a été envoyé.")
        }
        // Parti = notre texte a quitté le champ (vide, il renvoie de nouveau son texte d'invite).
        let gone = { !normalized(string(field, kAXValueAttribute)).contains(mine) }
        if let button = sendButton(near: field), (attribute(button, kAXEnabledAttribute) as? Bool) ?? false {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        if !wait(0.8, gone) { press(app.processIdentifier, 36) }  // Entrée, envoyée à VS Code seul
        return wait(2, gone) ? .sent : .failed("Le texte est dans Claude, mais pas parti : appuie sur Entrée.")
    }

    /// Le champ « Message input » de l'onglet qui a le focus. On cherche seulement dans la page
    /// (web area) qui contient le focus, sans descendre dans d'autres pages : si VS Code affiche une
    /// boîte de dialogue, on ne trouve rien plutôt que le champ d'une autre session.
    private static func input(in app: AXUIElement) -> AXUIElement? {
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        if label(focused) == "Message input" { return focused }
        guard let area = webArea(of: focused) else { return nil }
        return search(area) { label($0) == "Message input" }
    }

    private static func sendButton(near field: AXUIElement) -> AXUIElement? {
        guard let area = webArea(of: field) else { return nil }
        return search(area) { e in
            string(e, kAXRoleAttribute) == kAXButtonRole as String
                && [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].contains { string(e, $0) == "Send message" }
        }
    }

    private static func webArea(of e: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = e
        for _ in 0..<80 {
            guard let c = cur else { return nil }
            if string(c, kAXRoleAttribute) == "AXWebArea" { return c }
            cur = element(c, kAXParentAttribute)
        }
        return nil
    }

    private static func search(_ root: AXUIElement, limit: Int = 6000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = (attribute(root, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        var seen = 0
        while !queue.isEmpty && seen < limit {
            let e = queue.removeFirst()
            seen += 1
            if match(e) { return e }
            if string(e, kAXRoleAttribute) == "AXWebArea" { continue }  // une autre page
            queue += (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    // MARK: Outils

    private static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String { (attribute(e, name) as? String) ?? "" }

    private static func label(_ e: AXUIElement) -> String {
        let d = string(e, kAXDescriptionAttribute)
        return d.isEmpty ? string(e, kAXTitleAttribute) : d
    }

    private static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{200B}" }).joined(separator: " ")
    }

    private static func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < end
        return condition()
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

/// Le presse-papiers est emprunté le temps de coller, puis rendu tel quel.
private enum Clipboard {
    struct Saved { let items: [NSPasteboardItem]; let change: Int }

    static func put(_ text: String) -> Saved {
        let pb = NSPasteboard.general
        let items = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Les gestionnaires de presse-papiers ignorent ce contenu de passage.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        return Saved(items: items, change: pb.changeCount)
    }

    static func restore(_ saved: Saved) {
        let pb = NSPasteboard.general
        guard pb.changeCount == saved.change else { return }  // on a copié autre chose entre-temps
        pb.clearContents()
        if !saved.items.isEmpty { pb.writeObjects(saved.items) }
    }
}
