import AppKit
import IOBluetooth

/// Écouteurs et appareils Bluetooth connectés, avec leur batterie (AirPods : gauche, droite, boîtier).
/// À la connexion d'écouteurs, l'encoche affiche leur batterie, comme sur l'iPhone.
@MainActor
final class Devices: NSObject, ObservableObject {
    static let shared = Devices()

    struct Device: Identifiable, Equatable {
        let name: String
        var left: Int?, right: Int?, box: Int?, main: Int?
        var id: String { name }

        /// « G 80 % · D 75 % · boîtier 40 % », ou « 64 % ».
        var summary: String {
            var parts: [String] = []
            if let left { parts.append("G \(left) %") }
            if let right { parts.append("D \(right) %") }
            if let box { parts.append("boîtier \(box) %") }
            if parts.isEmpty, let main { parts.append("\(main) %") }
            return parts.joined(separator: " · ")
        }
        var hasBattery: Bool { left != nil || right != nil || box != nil || main != nil }
    }

    @Published private(set) var devices: [Device] = []
    private var connectNote: IOBluetoothUserNotification?

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        refresh()
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        let name = device.name ?? "Appareil"
        // La batterie n'est connue que quelques secondes après la connexion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.refresh { list in
                guard let d = list.first(where: { $0.name == name }), d.hasBattery else { return }
                Store.shared.showToast(Toast(icon: name.lowercased().contains("airpods") ? "airpods" : "headphones",
                                             color: "#8E9BB0", title: name, text: d.summary))
            }
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        refresh()
    }

    /// Lit les appareils connectés (system_profiler, en arrière-plan : une seconde ou deux).
    func refresh(then done: (([Device]) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let list = Self.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Devices.shared.devices = list
                    done?(list)
                }
            }
        }
    }

    nonisolated private static func scan() -> [Device] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        func pct(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) } }
        var found: [Device] = []
        for block in blocks {
            for entry in block["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    found.append(Device(name: name, left: pct(info["device_batteryLevelLeft"]), right: pct(info["device_batteryLevelRight"]),
                                        box: pct(info["device_batteryLevelCase"]), main: pct(info["device_batteryLevelMain"])))
                }
            }
        }
        return found
    }
}
