import AppKit
import SwiftUI

// Onglet Potes : les bonshommes du groupe et le chat.

/// Entre potes : les bonshommes du groupe (humeur, présence ; un clic envoie un cœur), ou le chat.
struct FriendsPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var friends = Friends.shared
    @ObservedObject var cam = FriendCam.shared
    @State private var focusNote = false

    var body: some View {
        Card(wash: Color(hex: "#F472B6", 0.24)) {
            Group {
                if !friends.configured {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            big("Joue avec tes potes.")
                            sub("Crée un groupe, donne-leur le code : vous verrez vos bonshommes ici, et vous pourrez discuter.")
                        }
                        Spacer()
                        Button("Configurer") { SettingsWindow.show() }.buttonStyle(Pill(primary: true))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        if friends.noteDraft != nil { noteEditor } else {
                        HStack(spacing: 8) {
                            Segments(left: "Potes", right: friends.unread > 0 ? "Chat \(friends.unread)" : "Chat", rightOn: store.friendsShowsChat) { on in
                                Sound.shared.play("tick")
                                withAnimation(Store.openAnimation) { store.friendsShowsChat = on }
                            }
                            if let n = friends.notice {
                                Text(n).font(Fonts.label.weight(.medium)).foregroundStyle(Color(hex: "#FF9ECF")).lineLimit(1)
                            } else if !cam.calls.isEmpty {
                                // En appel : « Raccrocher » reste toujours là ; une autre proposition s'ajoute à côté.
                                let others = cam.watchers.filter { cam.calls[$0.key] == nil }.values.sorted()
                                Label("Caméra avec \(cam.calls.values.sorted().joined(separator: ", "))"
                                      + (others.isEmpty ? "" : " · \(others.joined(separator: ", ")) te regarde"), systemImage: "video.fill")
                                    .font(Fonts.label.weight(.medium)).foregroundStyle(Color(hex: "#FF9ECF")).lineLimit(1)
                                if let invite = cam.invites.first {
                                    Button("Accepter \(invite.value)") { cam.accept(invite.key) }.buttonStyle(Chip())
                                }
                                Button("Raccrocher") { cam.hangUp() }.buttonStyle(Chip())
                            } else if let invite = cam.invites.first {
                                Label("\(invite.value) te propose la caméra", systemImage: "video.fill")
                                    .font(Fonts.label.weight(.medium)).foregroundStyle(Color(hex: "#FF9ECF")).lineLimit(1)
                                Button("Accepter") { cam.accept(invite.key) }.buttonStyle(Chip())
                                Button("Non") { cam.decline(invite.key) }.buttonStyle(Chip())
                            } else if !cam.watchers.isEmpty {
                                // Ma caméra est allumée pour quelqu'un : ça se voit, et ça se coupe d'un clic.
                                Label("\(cam.watchers.values.sorted().joined(separator: ", ")) te regarde", systemImage: "eye.fill")
                                    .font(Fonts.label.weight(.medium)).foregroundStyle(Color(hex: "#FF9ECF")).lineLimit(1)
                                Button("Couper ma caméra") { cam.setSharing(false) }.buttonStyle(Chip())
                            } else if !store.friendsShowsChat {
                                Text(friends.list.isEmpty ? "Donne le code du groupe à tes potes." : "Clic : un cœur · survol : coucou")
                                    .font(Fonts.label).foregroundStyle(Color.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            // Mon statut, visible sous mon bonhomme chez les potes.
                            Button {
                                friends.noteDraft = friends.note
                                focusNote = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "text.bubble").font(.system(size: 10, weight: .semibold))
                                    Text(friends.note.isEmpty ? "Ton statut" : friends.note).lineLimit(1)
                                }
                                .frame(maxWidth: 150)
                            }
                            .buttonStyle(Chip())
                            .help("Ton statut, visible sous ton bonhomme chez tes potes")
                            camButton
                        }
                        .animation(.easeOut(duration: 0.2), value: friends.notice)
                        }
                        if store.friendsShowsChat {
                            ChatView(store: store)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 6) {
                                    ForEach(friends.list) { f in FriendTile(friend: f) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.leading, 100)
            .padding(.trailing, 14)
            .padding(.vertical, 11)
        }
        // Dans le chat, les caméras des potes prennent la place du bonhomme, à gauche.
        .overlay(alignment: .leading) {
            if friends.configured && store.friendsShowsChat { ChatCams().padding(.leading, 9) }
        }
        // Onglet Potes ouvert (vignettes ou chat) : on demande l'image de ceux qui partagent leur caméra.
        .onAppear { cam.setViewing(true) }
        .onDisappear { cam.setViewing(false) }
    }
}

extension FriendsPanel {
    /// Écrire son statut, à la place de l'en-tête (Entrée valide, vide = effacé). Le bouton caméra reste là : il
    /// dit si ma caméra filme, et raccroche pendant une caméra ensemble.
    var noteEditor: some View {
        let draft = friends.noteDraft ?? ""
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: "#FF9ECF"))
                ComposeField(text: Binding(get: { friends.noteDraft ?? "" }, set: { friends.noteDraft = $0 }),
                             placeholder: "Ton statut (ex. en call client) · Entrée pour valider",
                             onSubmit: { friends.setNote(friends.noteDraft ?? "") },
                             onEditing: { editing in
                                 store.setComposing(editing)
                                 // Échap ou clic ailleurs sans rien changer : on referme l'éditeur.
                                 if !editing && friends.noteDraft == friends.note { friends.noteDraft = nil }
                             },
                             focus: focusNote, onFocused: { focusNote = false })
                    .frame(height: 18)
                Text("\(Friends.noteLimit - draft.count)").font(Fonts.caption).monospacedDigit()
                    .foregroundStyle(draft.count > Friends.noteLimit ? Color.danger : Color.faint)
                Button("OK") { friends.setNote(draft) }.buttonStyle(Chip())
                Button("Annuler") { friends.noteDraft = nil; store.setComposing(false) }.buttonStyle(Chip())
            }
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(0.1)))
            camButton
        }
    }

    /// Ma caméra : partagée ou non, en un clic (le même réglage que dans les Réglages) ; en appel, elle raccroche.
    var camButton: some View {
        let inCall = !cam.calls.isEmpty, on = cam.sharing || inCall
        return Button {
            if inCall { return cam.hangUp() }  // en appel, la caméra filme : le bouton raccroche
            cam.setSharing(!cam.sharing)
            Sound.shared.play("tick")
            friends.say(cam.sharing ? "Caméra partagée : tes potes peuvent te voir" : "Caméra coupée")
        } label: {
            Image(systemName: on ? "video.fill" : "video.slash.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(on ? Color(hex: "#FF9ECF") : Color.muted)
        }
        .buttonStyle(IconButton())
        .help(inCall ? "Caméra ensemble en cours : clic pour raccrocher"
              : cam.sharing ? "Ta caméra est partagée : clic pour la couper" : "Partager ta caméra avec tes potes")
        .accessibilityLabel(inCall ? "Raccrocher" : cam.sharing ? "Couper le partage de ma caméra" : "Partager ma caméra")
    }
}

/// Les caméras des potes à gauche du chat : une grande, ou deux l'une sous l'autre.
struct ChatCams: View {
    @ObservedObject var friends = Friends.shared
    @ObservedObject var frames = FriendCam.Frames.shared

    var body: some View {
        let live = friends.list.filter { frames.images[$0.id] != nil }
        VStack(spacing: 8) {
            ForEach(live.prefix(2)) { f in
                VStack(spacing: 3) {
                    if let image = frames.images[f.id] {
                        Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                            .frame(width: 84, height: live.count > 1 ? 63 : 84)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topLeading) { Circle().fill(Color.danger).frame(width: 6, height: 6).padding(6) }
                    }
                    Text(f.name).font(Fonts.caption.weight(.semibold)).foregroundStyle(Color.soft).lineLimit(1)
                }
                .frame(width: 84)
                .contentShape(Rectangle())
                .onTapGesture { Friends.shared.poke(f, "heart") }
                .help("\(f.name), en direct · clic : un cœur")
                .accessibilityLabel("Caméra de \(f.name), en direct")
            }
            if live.count > 2 {
                Text("+\(live.count - 2) en direct").font(Fonts.caption).foregroundStyle(Color.faint)
            }
        }
    }
}

/// Chat du groupe : messages regroupés par personne, l'heure aux pauses, l'état de mes messages,
/// des réponses rapides quand c'est vide, et le champ (Entrée envoie).
struct ChatView: View {
    @ObservedObject var store: Store
    @ObservedObject var friends = Friends.shared

    private static let quick = ["Salut 👋", "Qui code en ce moment ?", "Pause café ?", "Je lance un build 🚀"]

    var body: some View {
        VStack(spacing: 6) {
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if friends.chat.isEmpty { empty }
                        ForEach(Array(friends.chat.enumerated()), id: \.element.id) { i, m in
                            let prev = i > 0 ? friends.chat[i - 1] : nil
                            let pause = prev.map { m.at.timeIntervalSince($0.at) > 10 * 60 } ?? true
                            if pause { TimeSeparator(date: m.at) }
                            ChatRow(message: m, color: color(m), first: pause || prev?.from != m.from)
                        }
                        if let last = friends.chat.last, last.mine, last.state == "sent" || last.state == nil {
                            let names = friends.seenNames(after: last.at)
                            if !names.isEmpty {
                                Text("Vu par \(names.joined(separator: ", "))").font(Fonts.caption).foregroundStyle(Color.faint)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding(.horizontal, 2)
                }
                .onAppear { reader.scrollTo("fin", anchor: .bottom); friends.markRead() }
                .onChange(of: friends.chat.last?.id) { _, _ in  // (pas `count` : le chat plafonné à 150 ne bouge plus)
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("fin", anchor: .bottom) }
                    friends.markRead()
                }
            }
            input
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("Pas encore de message. Lance la conversation :").font(Fonts.label).foregroundStyle(Color.muted)
            HStack(spacing: 5) {
                ForEach(Self.quick, id: \.self) { q in Button(q) { friends.sendChat(q) }.buttonStyle(Chip()) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var input: some View {
        let count = friends.draft.count, empty = friends.draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            ComposeField(text: $friends.draft, placeholder: "Écris à tes potes…",
                         onSubmit: { friends.sendChat() }, onEditing: { store.setComposing($0) })
                .frame(height: 18)
            if count > Friends.chatLimit - 100 {  // on approche de la limite
                Text("\(Friends.chatLimit - count)").font(Fonts.caption).monospacedDigit()
                    .foregroundStyle(count > Friends.chatLimit ? Color.danger : Color.faint)
            }
            Button { friends.sendChat() } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.onLight)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(hex: "#FF8BC4")))
            }
            .buttonStyle(.plain)
            .opacity(empty ? 0.35 : 1)
            .disabled(empty)
            .help("Envoyer (Entrée)")
            .accessibilityLabel("Envoyer le message")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(store.composing ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(.white.opacity(store.composing ? 0.16 : 0.04)))
    }

    private func color(_ m: Friends.Message) -> String {
        let f = friends.list.first { $0.id == m.from }
        return f?.mochi.tint ?? f?.mochi.skin.aura ?? "#FF8BC4"
    }
}

/// « Aujourd'hui 14:32 », « Hier 22:10 », « 18 oct. 09:05 » : quand la conversation a fait une pause.
struct TimeSeparator: View {
    let date: Date
    var body: some View {
        Text(label).font(Fonts.caption.weight(.medium)).foregroundStyle(Color.faint)
            .frame(maxWidth: .infinity).padding(.vertical, 5)
    }
    private var label: String {
        let cal = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Aujourd'hui \(time)" }
        if cal.isDateInYesterday(date) { return "Hier \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }
}

/// Une bulle. Pour un pote : sa pastille et son nom au premier message d'une série. Pour moi : l'état.
struct ChatRow: View {
    let message: Friends.Message
    let color: String
    let first: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.mine {
                Spacer(minLength: 70)
            } else {
                Group {
                    if first { Avatar(name: message.name, color: color, size: 20) } else { Color.clear.frame(width: 20, height: 1) }
                }
                .padding(.bottom, 1)
            }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 2) {
                if first && !message.mine {
                    Text(message.name).font(Fonts.caption.weight(.semibold)).foregroundStyle(Color(hex: color))
                }
                Text(message.text)
                    .font(Fonts.label)
                    .foregroundStyle(message.mine ? Color.onLight : Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(message.mine ? Color(hex: "#FF8BC4") : .white.opacity(0.09)))
                    .opacity(message.state == "sending" ? 0.6 : 1)
                    // Survol : réagir d'un clic, en haut de la bulle (comme dans Messages).
                    .overlay(alignment: message.mine ? .topTrailing : .topLeading) {
                        if hover && (message.state == nil || message.state == "sent") { reactionBar.offset(y: -22) }
                    }
                    .zIndex(1)
                if let r = message.reactions, !r.isEmpty { reactions(r) }
                if message.mine, let state = message.state, state != "sent" { status(state) }
            }
            .help(message.at.formatted(date: .abbreviated, time: .shortened))
            .onHover { hover = $0 }
            if !message.mine { Spacer(minLength: 70) }
        }
        .padding(.top, first ? 5 : 0)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var reactionBar: some View {
        HStack(spacing: 1) {
            ForEach(Friends.reactionEmojis, id: \.self) { e in
                Button { Friends.shared.react(message, e) } label: { Text(e).font(.system(size: 13)).frame(width: 20, height: 20) }
                    .buttonStyle(HoverDim())
                    .accessibilityLabel("Réagir \(e)")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color(hex: "#2A2C33")))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
    }

    /// Les réactions sous la bulle : « 👍 2 » ; la mienne en surbrillance, un clic l'enlève ou l'ajoute.
    private func reactions(_ r: [String: [String]]) -> some View {
        let me = Friends.shared.me
        return HStack(spacing: 3) {
            ForEach(Friends.reactionEmojis.filter { r[$0] != nil }, id: \.self) { e in
                let people = r[e] ?? []
                Button { Friends.shared.react(message, e) } label: {
                    Text("\(e) \(people.count)").font(Fonts.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(people.contains(me) ? Color(hex: "#FF8BC4").opacity(0.35) : .white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(people.map(Self.who).joined(separator: ", "))
            }
        }
    }

    /// « toi », ou le prénom du pote.
    private static func who(_ id: String) -> String {
        if id == Friends.shared.me { return "toi" }
        return Friends.shared.list.first { $0.id == id }?.name ?? "un pote"
    }

    @ViewBuilder private func status(_ state: String) -> some View {
        if state == "failed" {
            Button { Friends.shared.retry(message) } label: {
                Label("Non envoyé · Réessayer", systemImage: "exclamationmark.circle.fill")
                    .font(Fonts.caption.weight(.medium)).foregroundStyle(Color.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message non envoyé, réessayer")
        } else {
            Text("Envoi…").font(Fonts.caption).foregroundStyle(Color.faint)
        }
    }
}

struct FriendTile: View {
    let friend: Friends.Friend
    @ObservedObject var friends = Friends.shared
    @ObservedObject var frames = FriendCam.Frames.shared
    @ObservedObject var cam = FriendCam.shared
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            if let image = frames.images[friend.id] {
                // Sa caméra, en direct (comme le Miroir, mais chez lui).
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Circle().fill(Color.danger).frame(width: 6, height: 6).padding(5)
                    }
                    .accessibilityLabel("Caméra de \(friend.name), en direct")
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    Canvas { ctx, size in
                        _ = tl.date
                        friend.mochi.update(CACurrentMediaTime())
                        friend.mochi.draw(ctx, cx: size.width / 2, cy: size.height / 2 + 4, hb: 28)
                    }
                }
                .frame(width: 84, height: 56)
                .saturation(friend.dnd ? 0 : 1)  // ne pas déranger : grisé, avec une lune
                .opacity(friend.online ? (friend.dnd ? 0.45 : friend.presence == .away ? 0.7 : 1) : 0.4)
                .overlay(alignment: .topTrailing) {
                    if friend.dnd && friend.online {
                        Image(systemName: "moon.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hex: "#A78BFA")).padding(4)
                    }
                }
            }
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(friend.name).font(Fonts.labelBold).lineLimit(1)
                if friends.watched.contains(friend.id) {
                    Image(systemName: "bell.fill").font(.system(size: 8)).foregroundStyle(Color.faint)
                        .help("Je te préviens quand \(friend.name) arrive sur son Mac")
                }
            }
            Text(status)
                .font(Fonts.caption)
                .foregroundStyle(friend.online && friend.presence == .active && !friend.dnd ? Color(hex: STYLES[friend.state]?.col ?? "#9A9FA8") : Color.faint)
                .lineLimit(1)
            // Son statut perso, sinon ce qu'il écoute (un clic l'ouvre dans Spotify).
            if !friend.note.isEmpty && friend.online {
                Text("« \(friend.note) »").font(Fonts.caption).italic().foregroundStyle(Color.soft).lineLimit(1)
                    .help(friend.note)
            } else if let music = friend.music, friend.online {
                Button { if let id = friend.musicID, let url = URL(string: id) { NSWorkspace.shared.open(url) } } label: {
                    Label(music, systemImage: "music.note").font(Fonts.caption).foregroundStyle(Color.spotify).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("\(friend.name) écoute « \(music) » : clic pour l'écouter")
            }
        }
        .frame(width: 96)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.item, style: .continuous).fill(.white.opacity(hover ? 0.09 : 0.03)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { Friends.shared.poke(friend, "wave") } label: { Image(systemName: "hand.wave.fill").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(MiniIcon())
                    .help("Faire coucou à \(friend.name)")
                    .accessibilityLabel("Faire coucou à \(friend.name)")
            }
        }
        .overlay(alignment: .topLeading) {
            if hover && friend.online && frames.images[friend.id] == nil {
                Button { FriendCam.shared.propose(friend) } label: { Image(systemName: "video.fill").font(.system(size: 9.5, weight: .semibold)) }
                    .buttonStyle(MiniIcon())
                    .help("Proposer la caméra à \(friend.name)")
                    .accessibilityLabel("Proposer la caméra à \(friend.name)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Friends.shared.poke(friend, "heart") }
        .contextMenu {
            Button("Envoyer un cœur") { Friends.shared.poke(friend, "heart") }
            Button("Faire coucou") { Friends.shared.poke(friend, "wave") }
            if friend.online { Button("Proposer la caméra") { FriendCam.shared.propose(friend) } }
            Button(friends.watched.contains(friend.id) ? "Ne plus me prévenir quand il arrive" : "Me prévenir quand il arrive sur son Mac") {
                Friends.shared.toggleWatch(friend)
            }
            if let id = friend.musicID, let music = friend.music {
                Button("Écouter « \(music) »") { if let url = URL(string: id) { NSWorkspace.shared.open(url) } }
            }
        }
        .help("Envoyer un cœur à \(friend.name)")
        .accessibilityLabel("\(friend.name), \(status)")
    }

    /// Vert : sur son Mac. Violet : ne pas déranger. Orange : absent. Gris : hors ligne.
    private var dot: Color {
        !friend.online ? Color.faint : friend.dnd ? Color(hex: "#A78BFA") : friend.presence == .active ? Color.success : Color.warning
    }

    private var status: String {
        guard friend.online else { return "hors ligne" }
        if frames.images[friend.id] != nil { return "en direct" }
        if friend.dnd { return "ne pas déranger" }
        if friend.cam && cam.failed.contains(friend.id) { return "caméra injoignable" }
        if friend.presence == .away {
            let m = Int(Date().timeIntervalSince(friend.since) / 60)
            return m < 1 ? "absent" : m < 60 ? "absent · \(m) min" : "absent · \(m / 60) h"
        }
        switch friend.state {
        case .working: return "Claude travaille"
        case .approval: return "attend une autorisation"
        case .waiting: return "attend sa réponse"
        case .error: return "a un souci"
        case .sleeping: return "sur son Mac"
        case .finished, .idle, .dizzy: return "sur son Mac"
        }
    }
}
