import Foundation

/// Les skins du bonhomme : une palette (haut, bas, lueur) et un accessoire. Choisis dans les Réglages
/// ou d'un clic droit ; tes potes voient le tien.
enum Accessory { case none, kippah, fez, nonLa, headphones, crown, beanie, cap }

struct Skin: Identifiable, Equatable {
    let id: String
    let name: String
    let top: String
    let bottom: String
    let aura: String
    let accessory: Accessory

    static let all = [
        Skin(id: "galet", name: "Galet", top: "#FF8BC4", bottom: "#7B3DF2", aura: "#8F4BFF", accessory: .none),
        Skin(id: "kippa", name: "Kippa", top: "#FF8BC4", bottom: "#7B3DF2", aura: "#8F4BFF", accessory: .kippah),
        Skin(id: "turc", name: "Turc", top: "#FF8BC4", bottom: "#8E44F0", aura: "#8F4BFF", accessory: .fez),
        Skin(id: "vietnam", name: "Vietnam", top: "#F55BB4", bottom: "#7A2EE6", aura: "#8F4BFF", accessory: .nonLa),
        Skin(id: "dj", name: "DJ", top: "#6EF2C2", bottom: "#168F86", aura: "#2DD4A7", accessory: .headphones),
        Skin(id: "roi", name: "Roi", top: "#B892FF", bottom: "#4F22C9", aura: "#7C4DFF", accessory: .crown),
        Skin(id: "hiver", name: "Hiver", top: "#BFE6FF", bottom: "#3F86DE", aura: "#6FB7FF", accessory: .beanie),
        Skin(id: "skater", name: "Skater", top: "#FFB36B", bottom: "#F2475A", aura: "#FF7A59", accessory: .cap),
    ]

    static func named(_ id: String?) -> Skin { all.first { $0.id == id } ?? all[1] }

    /// Le skin choisi (la kippa par défaut).
    static var current: Skin { named(UserDefaults.standard.string(forKey: "skin")) }

    /// Couleur choisie pour le bonhomme (nil : celle du skin).
    static var tint: String? {
        let c = UserDefaults.standard.string(forKey: "skin.color") ?? ""
        return c.isEmpty ? nil : c
    }

    /// Couleurs proposées (en plus du nuancier).
    static let colors: [(name: String, hex: String)] = [
        ("Rose", "#F25FB0"), ("Violet", "#8B5CF6"), ("Bleu", "#3B82F6"), ("Cyan", "#22C3E6"), ("Vert", "#22C55E"),
        ("Jaune", "#F5C518"), ("Orange", "#F97316"), ("Rouge", "#EF4444"), ("Nuit", "#334155"),
    ]
}
