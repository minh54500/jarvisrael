import AppKit
import SwiftUI

// Champ de saisie de la section de gauche. C'est un vrai NSTextField : le panneau de l'encoche ne
// prend le clavier qu'au clic dans ce champ, et le rend dès qu'on a fini (Entrée, Échap, clic ailleurs).

struct ComposeField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onEditing: (Bool) -> Void
    /// Demande de prendre le clavier (raccourci ⌥Espace, capture) ; `onFocused` la consomme.
    var focus = false
    var onFocused: () -> Void = {}

    func makeNSView(context: Context) -> FieldView {
        let f = FieldView()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.textColor = NSColor(white: 0.96, alpha: 1)
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byTruncatingTail
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.36), .font: NSFont.systemFont(ofSize: 13),
        ])
        f.delegate = context.coordinator
        f.onBegin = { context.coordinator.parent.onEditing(true) }
        return f
    }

    func updateNSView(_ f: FieldView, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text {
            f.stringValue = text
            f.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)  // curseur à la fin
        }
        if focus && !context.coordinator.grabbing {
            context.coordinator.grabbing = true
            grab(f, context.coordinator, tries: 10)
        }
    }

    /// Prend le clavier dès que le champ est dans la fenêtre (il peut être en train d'apparaître).
    /// Une seule tentative à la fois, et rien si le champ écrit déjà : le reprendre couperait l'écriture
    /// en cours, et l'encoche rendrait puis reprendrait le clavier (elle clignoterait).
    private func grab(_ f: FieldView, _ coordinator: Coordinator, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let panel = f.window as? NotchPanel else {
                if tries > 0 { grab(f, coordinator, tries: tries - 1) } else { coordinator.grabbing = false }
                return
            }
            coordinator.grabbing = false
            onFocused()
            guard f.currentEditor() == nil else { return }
            panel.takeKeyboard()
            panel.makeFirstResponder(f)
            f.currentEditor()?.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposeField
        var grabbing = false
        init(_ parent: ComposeField) { self.parent = parent }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):  // Échap
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ n: Notification) { parent.onEditing(false) }
    }
}

final class FieldView: NSTextField {
    var onBegin: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        (window as? NotchPanel)?.takeKeyboard()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBegin?() }
        return ok
    }

    /// ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z : l'app n'a pas de menu Édition, on les relaie nous-mêmes.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let editor = currentEditor() as? NSTextView,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": editor.pasteAsPlainText(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "a": editor.selectAll(nil)
        case "z": editor.undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
