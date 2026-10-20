import Foundation

/// Les skins du bonhomme : une palette (haut, bas, lueur) et un accessoire. Choisis dans les Réglages
/// ou d'un clic droit ; tes potes voient le tien.
enum Accessory { case none, kippah, fez, headphones, crown, beanie, cap }

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
        Skin(id: "dj", name: "DJ", top: "#6EF2C2", bottom: "#168F86", aura: "#2DD4A7", accessory: .headphones),
        Skin(id: "roi", name: "Roi", top: "#B892FF", bottom: "#4F22C9", aura: "#7C4DFF", accessory: .crown),
        Skin(id: "hiver", name: "Hiver", top: "#BFE6FF", bottom: "#3F86DE", aura: "#6FB7FF", accessory: .beanie),
        Skin(id: "skater", name: "Skater", top: "#FFB36B", bottom: "#F2475A", aura: "#FF7A59", accessory: .cap),
    ]

    static func named(_ id: String?) -> Skin { all.first { $0.id == id } ?? all[1] }

    /// Le skin choisi (la kippa par défaut).
    static var current: Skin { named(UserDefaults.standard.string(forKey: "skin")) }
}
