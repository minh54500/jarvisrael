import AppKit
import SwiftUI

/// Prompteur : ton texte défile juste sous la caméra, pour lire en regardant l'objectif (vidéo, démo,
/// visio). L'encoche est invisible dans les partages d'écran (voir AppDelegate), le prompteur aussi.
@MainActor
final class Prompter: ObservableObject {
    static let shared = Prompter()

    @Published var script = UserDefaults.standard.string(forKey: "prompter.script")
        ?? "Colle ou écris ton texte ici.\n\nAppuie sur Lancer : il défile sous la caméra, tu lis en regardant l'objectif." {
        didSet { UserDefaults.standard.set(script, forKey: "prompter.script") }
    }
    @Published private(set) var speed = UserDefaults.standard.object(forKey: "prompter.speed") as? Double ?? 28 {  // points par seconde
        didSet { UserDefaults.standard.set(speed, forKey: "prompter.speed") }
    }
    @Published var size = UserDefaults.standard.object(forKey: "prompter.size") as? Double ?? 22 {
        didSet { UserDefaults.standard.set(size, forKey: "prompter.size") }
    }
    @Published private(set) var showing = false  // en lecture (défilement ou pause)
    @Published private(set) var playing = false
    var textHeight = 0.0
    private var base = 0.0          // décalage au dernier départ ou à la dernière pause
    private var since: Date?        // départ du défilement en cours

    /// Où en est le texte à cet instant (calculé, pas stocké : fluide à chaque image).
    func offset(at now: Date) -> Double {
        let v = base + (since.map { now.timeIntervalSince($0) * speed } ?? 0)
        return textHeight > 0 ? min(v, textHeight) : v
    }

    func start() {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        base = 0
        since = Date()
        showing = true
        playing = true
        Sound.shared.play("open")
    }

    func toggle() {
        if playing { base = offset(at: Date()); since = nil } else { since = Date() }
        playing.toggle()
    }

    func faster(_ step: Double) {
        let now = Date()
        base = offset(at: now)
        if since != nil { since = now }
        speed = max(8, min(120, speed + step))
    }

    func restart() {
        base = 0
        since = Date()
        playing = true
    }

    func stop() {
        showing = false
        playing = false
        since = nil
        base = 0
    }
}

/// Champ de texte sur plusieurs lignes qui prend le clavier de l'encoche au clic (comme ComposeField).
struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String
    var onEditing: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = ScriptTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12.5)
        tv.textColor = NSColor(white: 0.92, alpha: 1)
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        tv.delegate = context.coordinator
        tv.onFocus = { context.coordinator.parent.onEditing($0) }
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = scroll.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptEditor
        init(_ parent: ScriptEditor) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
    }
}

final class ScriptTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        (window as? NotchPanel)?.takeKeyboard()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }

    override func cancelOperation(_ sender: Any?) { window?.makeFirstResponder(nil) }  // Échap

    /// ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z sans menu Édition au premier plan.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": pasteAsPlainText(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "z": undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
