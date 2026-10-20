import SwiftUI

// Jetons de l'interface : couleurs, textes, rayons. Les vues n'écrivent plus de hex en dur.
// Contrastes mesurés sur la carte (surface) : ink 17:1, soft 11:1, muted 7:1, faint 4.8:1.

extension Color {
    static let ink = Color(hex: "#F5F6F8")       // texte principal
    static let soft = Color(hex: "#C9CCD2")      // texte secondaire appuyé
    static let muted = Color(hex: "#9A9FA8")     // texte secondaire, icônes
    static let faint = Color(hex: "#7F848D")     // légendes, éléments au repos
    static let surface = Color(hex: "#131417")   // cartes
    static let sunken = Color(hex: "#0F1013")    // zones de dépôt
    static let onLight = Color(hex: "#0B0C0E")   // texte sur bouton clair
    static let success = Color(hex: "#5EE0AE")
    static let danger = Color(hex: "#FF8D97")
    static let warning = Color(hex: "#F5A524")
    static let spotify = Color(hex: "#1ED760")
}

enum Fonts {
    static let caption = Font.system(size: 11)
    static let captionMono = Font.system(size: 11, design: .monospaced)
    static let label = Font.system(size: 12)
    static let labelBold = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 13)
    static let button = Font.system(size: 12.5, weight: .medium)
    static let lead = Font.system(size: 13.5, weight: .medium)
    static let title = Font.system(size: 15, weight: .semibold)
}

enum Radius {
    static let island = 30.0
    static let card = 20.0      // island − marge de 10 : coins concentriques
    static let control = 12.0
    static let item = 10.0
}
