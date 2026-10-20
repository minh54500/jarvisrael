import AppKit
import Carbon

/// Raccourcis globaux : ils marchent depuis n'importe quelle app, sans autorisation particulière.
/// ⌥Espace ouvre l'encoche prête à écrire à Claude ; ⌥⇧Espace l'ouvre et lance la dictée.
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static func register(id: UInt32, key: Int, modifiers: Int, _ action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKey.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x454E_4348, id: id),  // 'ENCH'
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
