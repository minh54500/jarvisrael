import AppKit
import SwiftUI

// Champ de saisie de la section de gauche. C'est un vrai NSTextField : le panneau de l'encoche ne
// prend le clavier qu'au clic dans ce champ, et le rend dès qu'on a fini (Entrée, Échap, clic ailleurs).

struct ComposeField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onEditing: (Bool) -> Void

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
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposeField
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
