import AppKit
import SwiftUI

// Onglet Potes : les bonshommes du groupe et le chat.

/// Entre potes : les bonshommes du groupe (humeur, présence ; un clic envoie un cœur), ou le chat.
struct FriendsPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var friends = Friends.shared

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
                        HStack(spacing: 8) {
                            Segments(left: "Potes", right: friends.unread > 0 ? "Chat \(friends.unread)" : "Chat", rightOn: store.friendsShowsChat) { on in
                                Sound.shared.play("tick")
                                withAnimation(Store.openAnimation) { store.friendsShowsChat = on }
                            }
                            if let n = friends.notice {
                                Text(n).font(Fonts.label.weight(.medium)).foregroundStyle(Color(hex: "#FF9ECF")).lineLimit(1)
                            } else if !store.friendsShowsChat {
                                Text(friends.list.isEmpty ? "Donne le code du groupe à tes potes." : "Clic : un cœur · survol : coucou")
                                    .font(Fonts.label).foregroundStyle(Color.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .animation(.easeOut(duration: 0.2), value: friends.notice)
                        if store.friendsShowsChat {
                            ChatView(store: store)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
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
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding(.horizontal, 2)
                }
                .onAppear { reader.scrollTo("fin", anchor: .bottom); friends.markRead() }
                .onChange(of: friends.chat.count) { _, _ in
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
                if message.mine, let state = message.state, state != "sent" { status(state) }
            }
            .help(message.at.formatted(date: .abbreviated, time: .shortened))
            if !message.mine { Spacer(minLength: 70) }
        }
        .padding(.top, first ? 5 : 0)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                Canvas { ctx, size in
                    _ = tl.date
                    friend.mochi.update(CACurrentMediaTime())
                    friend.mochi.draw(ctx, cx: size.width / 2, cy: size.height / 2 + 4, hb: 28)
                }
            }
            .frame(width: 84, height: 56)
            .opacity(friend.online ? (friend.presence == .away ? 0.7 : 1) : 0.4)
            HStack(spacing: 4) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(friend.name).font(Fonts.labelBold).lineLimit(1)
            }
            Text(status)
                .font(Fonts.caption)
                .foregroundStyle(friend.online && friend.presence == .active ? Color(hex: STYLES[friend.state]?.col ?? "#9A9FA8") : Color.faint)
                .lineLimit(1)
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
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { Friends.shared.poke(friend, "heart") }
        .contextMenu {
            Button("Envoyer un cœur") { Friends.shared.poke(friend, "heart") }
            Button("Faire coucou") { Friends.shared.poke(friend, "wave") }
        }
        .help("Envoyer un cœur à \(friend.name)")
        .accessibilityLabel("\(friend.name), \(status)")
    }

    /// Vert : sur son Mac. Orange : absent. Gris : hors ligne.
    private var dot: Color {
        !friend.online ? Color.faint : friend.presence == .active ? Color.success : Color.warning
    }

    private var status: String {
        guard friend.online else { return "hors ligne" }
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
