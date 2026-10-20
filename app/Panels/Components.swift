import AppKit
import SwiftUI

// Éléments communs des panneaux : cartes, boutons, pastilles, jauges, textes.

struct Card<Content: View>: View {
    var wash: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color.surface
                    if let wash {
                        RadialGradient(colors: [wash, .clear], center: UnitPoint(x: 0.5, y: 1.3), startRadius: 0, endRadius: 380)
                    }
                }
                .clipShape(shape)
            }
            // Liseré plus clair en haut : la carte semble éclairée par le dessus, comme du verre.
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct Pill: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, primary: primary) }
}

struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(Fonts.button)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .foregroundStyle(primary ? Color.onLight : Color.ink)
            .background(Capsule().fill(primary ? Color.ink.opacity(hover ? 0.88 : 1)
                                               : .white.opacity(configuration.isPressed ? 0.2 : hover ? 0.14 : 0.09)))
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.06)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Bouton-icône rond de 28 pt, éclairé au survol.
struct IconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconBody(configuration: configuration) }
}

struct IconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(hover ? Color.ink : Color.muted)
            .frame(width: 28, height: 28)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Bouton sans fond : s'éclaircit au survol, se tasse au clic.
struct HoverDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverDimBody(configuration: configuration) }
}

struct HoverDimBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .brightness(hover ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Who: View {
    let session: Session?
    let suffix: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: session?.color ?? "#FFFFFF")).frame(width: 8, height: 8)
            if let session { Text(session.name).fontWeight(.semibold) }
            if !suffix.isEmpty { Text(suffix).foregroundStyle(Color.muted) }
        }
        .font(Fonts.label)
        .lineLimit(1)
    }
}

func big(_ s: String) -> some View {
    Text(s).font(Fonts.title).lineLimit(2)
}

func sub(_ s: String, red: Bool = false) -> some View {
    Text(s).foregroundStyle(red ? Color.danger : Color.muted).lineLimit(2)
}

/// Petite pastille de texte (favoris, fichiers modifiés).
struct Chip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }
}

struct ChipBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(Fonts.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(hover ? Color.ink : Color.soft)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.18 : hover ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.05)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Bouton-icône du champ d'écriture (capture, micro).
struct MiniIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MiniIconBody(configuration: configuration) }
}

struct MiniIconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(hover ? Color.ink : Color.muted)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : hover ? 0.1 : 0)))
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}

/// Deux choix côte à côte, la pastille claire sur celui qui est actif.
struct Segments: View {
    let left: String
    let right: String
    let rightOn: Bool
    let pick: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { isRight in
                let on = isRight == rightOn
                Button { if !on { pick(isRight) } } label: {
                    Text(isRight ? right : left)
                        .font(Fonts.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(on ? Color.ink : Color.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(.white.opacity(on ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
        .animation(.easeOut(duration: 0.15), value: rightOn)
    }
}

struct RoundControl: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { RoundBody(configuration: configuration, primary: primary) }
}

struct RoundBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: primary ? 14 : 12.5, weight: .bold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(primary ? Color.onLight : Color.ink)
            .frame(width: primary ? 38 : 32, height: primary ? 38 : 32)
            .background(Circle().fill(primary ? Color.ink.opacity(hover ? 0.88 : 1)
                                              : .white.opacity(configuration.isPressed ? 0.16 : hover ? 0.09 : 0.0001)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Jauge de la santé du Mac : vert, puis orange et rouge quand ça monte (ou descend, pour la batterie).
struct Gauge: View {
    let label: String
    let value: Double?
    var invert = false

    var body: some View {
        let v = value ?? 0, load = invert ? 1 - v : v
        let tint: Color = load > 0.85 ? .danger : load > 0.65 ? .warning : .success
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(Color.muted)
                Spacer()
                Text(value.map { "\(Int(($0 * 100).rounded())) %" } ?? "—").monospacedDigit()
            }
            .font(Fonts.caption)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(3, g.size.width * v))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.4), value: v)
        }
    }
}
