import AppKit
import SwiftUI

// Onglet Musique : Spotify, paroles synchronisées, visualiseur.

/// Spotify : pochette, morceau, progression et commandes.
struct MusicPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var spotify = Spotify.shared

    var body: some View {
        Card(wash: Color(hex: "#1DB954", spotify.playing ? 0.34 : 0.16)) {
            Group {
                if let t = spotify.track { player(t) } else { idle }
            }
            .padding(.leading, 100)
            .padding(.trailing, 16)
        }
        .animation(.easeOut(duration: 0.4), value: spotify.playing)
    }

    private func player(_ t: Spotify.Track) -> some View {
        HStack(spacing: 14) {
            Button { spotify.open() } label: { cover }
                .buttonStyle(.plain)
                .help("Ouvrir Spotify")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(t.name).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                    if spotify.playing { Visualizer().frame(width: 16, height: 12) }
                }
                if spotify.denied {
                    sub("Autorise Encoche à piloter Spotify : Réglages Système → Confidentialité → Automatisation.", red: true)
                        .font(Fonts.caption)
                } else {
                    Text(t.artist).foregroundStyle(Color.muted).lineLimit(1)
                }
                LyricLine(spotify: spotify)
                Spacer(minLength: 2)
                MusicProgress(spotify: spotify)
            }
            .frame(height: 96)
            .onAppear { Lyrics.shared.load(t) }
            .onChange(of: t.id) { _, _ in Lyrics.shared.load(t) }
            HStack(spacing: 2) {
                Button { spotify.previous() } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(RoundControl()).help("Morceau précédent").accessibilityLabel("Morceau précédent")
                Button {
                    if !spotify.playing { store.mochi.emote(.happy, 0.8) }
                    spotify.playPause()
                } label: { Image(systemName: spotify.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(RoundControl(primary: true)).help(spotify.playing ? "Pause" : "Lecture")
                    .accessibilityLabel(spotify.playing ? "Pause" : "Lecture")
                Button { spotify.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(RoundControl()).help("Morceau suivant").accessibilityLabel("Morceau suivant")
            }
        }
    }

    private var cover: some View {
        Group {
            if let img = spotify.artwork {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(Color.faint)
                }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06)))
    }

    private var idle: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                big(spotify.running ? "Rien ne joue sur Spotify." : "Spotify n'est pas ouvert.")
                sub(spotify.running ? "Lance un morceau, il s'affichera ici." : "Ouvre-le pour piloter ta musique d'ici.")
            }
            Spacer()
            if spotify.running {
                Button("Lecture") { spotify.playPause() }.buttonStyle(Pill(primary: true))
            } else {
                Button("Ouvrir Spotify") { spotify.open() }.buttonStyle(Pill(primary: true))
            }
        }
    }
}

/// Petites barres qui dansent pendant la lecture (décoratives : macOS ne donne pas le son des autres apps).
struct Visualizer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = 0.35 + 0.65 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i) * 1.7))
                    Capsule().fill(Color.spotify).frame(width: 2.5, height: 12 * h)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// La ligne de paroles en cours (LRCLIB), et la suivante en plus discret.
struct LyricLine: View {
    @ObservedObject var spotify: Spotify
    @ObservedObject var lyrics = Lyrics.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { tl in
            if lyrics.loadedFor == spotify.track?.id, let l = lyrics.at(spotify.position(at: tl.date)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.current.isEmpty ? "♪" : l.current).font(Fonts.label.weight(.medium)).foregroundStyle(Color.soft).lineLimit(1)
                    if !l.next.isEmpty { Text(l.next).font(Fonts.caption).foregroundStyle(Color.faint).lineLimit(1) }
                }
                .animation(.easeOut(duration: 0.2), value: l.current)
            }
        }
    }
}

/// Barre de lecture : avance toute seule, un clic déplace la lecture.
struct MusicProgress: View {
    @ObservedObject var spotify: Spotify

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let d = max(1, spotify.track?.duration ?? 1), p = spotify.position(at: timeline.date)
            VStack(spacing: 2) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(Color.ink).frame(width: max(4, g.size.width * p / d))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { at in
                        spotify.seek(to: clamp(at.x / g.size.width, 0, 1) * d)
                    }
                }
                .frame(height: 12)
                HStack {
                    Text(time(p))
                    Spacer()
                    Text(time(d))
                }
                .font(Fonts.captionMono)
                .foregroundStyle(Color.faint)
            }
        }
    }

    private func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
