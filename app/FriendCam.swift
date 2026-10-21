import AppKit
import SwiftUI
import WebKit

/// La caméra entre potes : l'onglet Potes montre en direct (image seulement) ceux qui partagent leur caméra,
/// comme le Miroir mais chez eux. Personne n'appelle : chacun coche une fois « Partager ma caméra » dans les
/// Réglages, et sa caméra ne s'allume que pendant qu'un pote regarde (lumière verte du Mac, bulle « … te
/// regarde »). L'image passe directement d'un Mac à l'autre (WebRTC, dans une petite page web cachée sous
/// l'encoche) ; ntfy ne sert qu'à se mettre d'accord sur la connexion. Pas de relais : sur certains réseaux
/// (4G, Wi-Fi d'entreprise), la connexion directe ne passe pas.
@MainActor
final class FriendCam: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    static let shared = FriendCam()

    /// Les images reçues, à part : elles changent 10 fois par seconde, seules les vignettes les suivent.
    final class Frames: ObservableObject {
        @MainActor static let shared = Frames()
        @Published var images: [String: NSImage] = [:]  // pote → dernière image
    }

    @Published private(set) var sharing = UserDefaults.standard.bool(forKey: "cam.share")
    @Published private(set) var watchers: [String: String] = [:]  // potes qui me regardent : id → nom
    @Published private(set) var failed: Set<String> = []          // potes qu'on n'a pas réussi à joindre
    @Published private(set) var problem: String?                   // caméra refusée…
    /// La page n'existe que pendant qu'une image circule (dans un sens ou dans l'autre) ou que l'onglet est ouvert.
    @Published private(set) var active = false

    private var webView: WKWebView?
    private var ready = false
    private var queued: [String] = []
    private var viewing = false
    private var stopTimer: Timer?
    private var asked: [String: Date] = [:]  // pote → demande envoyée (une fois par ouverture de l'onglet)
    private var incoming = Set<String>()     // potes que je regarde (connexion en cours ou établie)
    private var outgoing = Set<String>()     // potes qui me regardent (connexion en cours ou établie)
    private var greeted: [String: Date] = [:]
    private var gaveUp: [String: Date] = [:]  // pote injoignable : on ne redemande pas avant 10 min
    private var pendingAsk: DispatchWorkItem?
    private var settled = false               // onglet ouvert depuis assez longtemps pour demander les images
    private var test: ((([String: Any]) -> Void))?

    // MARK: Réglage

    func setSharing(_ on: Bool, announce: Bool = true) {
        UserDefaults.standard.set(on, forKey: "cam.share")
        sharing = on
        problem = nil
        if !on { for id in outgoing { js("close('out:' + \(Self.quote(id)))") } }
        // Republie mon état tout de suite : les potes voient que la caméra est partagée (ou plus).
        if announce { Friends.shared.skinChanged() }
    }

    // MARK: Je regarde (onglet Potes ouvert)

    func setViewing(_ on: Bool) {
        stopTimer?.invalidate()
        stopTimer = nil
        pendingAsk?.cancel()
        if on {
            if !viewing {  // nouvelle ouverture : on redemande à chacun (sauf aux injoignables récents)
                asked = [:]
                settled = false
                failed = Set(gaveUp.filter { Date().timeIntervalSince($0.value) < 10 * 60 }.keys)
            }
            viewing = true
            refresh()
            // Un coup d'œil en passant la souris n'allume pas la caméra des potes : on attend un peu.
            let ask = DispatchWorkItem { FriendCam.shared.settled = true; FriendCam.shared.askAll() }
            pendingAsk = ask
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: ask)
        } else {
            // Petit délai : refermer et rouvrir l'onglet ne relance pas tout.
            stopTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
                MainActor.assumeIsolated { FriendCam.shared.stopViewing() }
            }
        }
    }

    /// Un pote a changé (caméra partagée ou plus, en ligne ou plus).
    func friendsChanged() {
        for f in Friends.shared.list {
            if incoming.contains(f.id) && (!f.cam || !f.online) { js("close('in:' + \(Self.quote(f.id)))") }
            if outgoing.contains(f.id) && !f.online { js("close('out:' + \(Self.quote(f.id)))") }  // parti sans prévenir
        }
        askAll()
    }

    private func askAll() {
        guard viewing, settled, stopTimer == nil, Friends.shared.configured else { return }
        for f in Friends.shared.list where f.cam && f.online && f.presence != .off && asked[f.id] == nil && !incoming.contains(f.id)
            && Date().timeIntervalSince(gaveUp[f.id] ?? .distantPast) > 10 * 60 {
            asked[f.id] = Date()
            Friends.shared.signal(["kind": "cam-watch", "to": f.id])
            let id = f.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {  // rien reçu : connexion directe impossible
                let cam = FriendCam.shared
                guard cam.viewing, Frames.shared.images[id] == nil else { return }
                cam.failed.insert(id)
                cam.gaveUp[id] = Date()
            }
        }
    }

    private func stopViewing() {
        stopTimer = nil  // un minuteur qui a sonné n'est pas nil : sans ça, l'onglet resterait « ouvert » pour toujours
        viewing = false
        settled = false
        for id in incoming {
            Friends.shared.signal(["kind": "cam-stop", "to": id])
            js("close('in:' + \(Self.quote(id)))")
        }
        Frames.shared.images = [:]
        refresh()
    }

    /// Plus de groupe, mise en veille : tout se coupe.
    func closeAll() {
        js("closeAll('')")
        incoming = []
        outgoing = []
        watchers = [:]
        Frames.shared.images = [:]
        refresh()
    }

    // MARK: Messages des potes (via ntfy)

    func handle(_ kind: String, from id: String, name: String, _ m: [String: Any]) {
        switch kind {
        case "cam-watch":  // un pote veut me voir
            guard sharing else { return }
            outgoing.insert(id)
            watchers[id] = nil
            refresh()
            js("offer(\(Self.quote(id)))")
        case "cam-offer":  // l'image d'un pote arrive
            guard viewing || stopTimer != nil, let sdp = Self.unpack(m["sdp"] as? String) else { return }
            incoming.insert(id)
            refresh()
            js("accept(\(Self.quote(id)), \(Self.quote(sdp)))")
        case "cam-answer":
            guard sharing, outgoing.contains(id), let sdp = Self.unpack(m["sdp"] as? String) else { return }
            js("answered(\(Self.quote(id)), \(Self.quote(sdp)))")
        case "cam-stop":
            js("close('out:' + \(Self.quote(id)))")
        default:
            break
        }
    }

    // MARK: La page (WebRTC)

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
            let id = m["id"] as? String ?? ""
            let key = m["key"] as? String ?? ""
            switch type {
            case "frame":
                guard let url = m["data"] as? String, let comma = url.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(url[url.index(after: comma)...])), let image = NSImage(data: data) else { return }
                if id == "selftest" { return }
                if incoming.contains(id) { Frames.shared.images[id] = image }
                if failed.contains(id) { failed.remove(id) }
            case "offer", "answer":
                guard let sdp = m["sdp"] as? String else { return }
                // Partage décoché (ou pote parti) pendant que la caméra démarrait : l'offre ne part pas.
                if type == "offer" && !(sharing && outgoing.contains(id)) { return js("close('out:' + \(Self.quote(id)))") }
                if type == "answer" && !incoming.contains(id) { return js("close('in:' + \(Self.quote(id)))") }
                Friends.shared.signal(["kind": "cam-" + type, "to": id, "sdp": Self.pack(sdp)])
            case "state":
                let who = String(key.drop { $0 != ":" }.dropFirst())
                if key.hasPrefix("out:") && m["state"] as? String == "connected" { watched(by: who) }
            case "closed":
                let who = String(key.drop { $0 != ":" }.dropFirst())
                if key.hasPrefix("out:") { outgoing.remove(who); watchers[who] = nil }
                if key.hasPrefix("in:") { incoming.remove(who); Frames.shared.images[who] = nil }
                refresh()
            case "error":
                let text = m["message"] as? String ?? ""
                if key.hasPrefix("out:") && text.contains("NotAllowed") {
                    problem = "La caméra est refusée à Encoche : autorise-la dans Réglages Système → Confidentialité → Caméra."
                }
                NSLog("Encoche caméra %@ : %@", key, text)
            default:
                break
            }
        }
    }

    private func watched(by id: String) {
        let name = Friends.shared.list.first { $0.id == id }?.name ?? "Un pote"
        watchers[id] = name
        if Date().timeIntervalSince(greeted[id] ?? .distantPast) > 10 * 60 {
            greeted[id] = Date()
            Store.shared.showToast(Toast(icon: "eye.fill", color: "#F472B6", title: name, text: "te regarde en direct", opens: .friends))
        }
    }

    nonisolated func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                             type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        MainActor.assumeIsolated {
            let cam = FriendCam.shared
            decisionHandler(type == .camera && (cam.sharing || cam.test != nil) ? .grant : .deny)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let cam = FriendCam.shared
            cam.ready = true
            for code in cam.queued { webView.evaluateJavaScript(code) }
            cam.queued = []
        }
    }

    /// La page est créée à la demande et tenue sous l'encoche (voir CamHost) : WebKit ne filme que pour une
    /// page affichée dans une fenêtre visible.
    var web: WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "cam")
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        w.uiDelegate = self
        w.navigationDelegate = self
        w.loadHTMLString(Self.page, baseURL: URL(string: "https://encoche.local/"))
        webView = w
        return w
    }

    private func js(_ code: String) {
        guard active || viewing || !incoming.isEmpty || !outgoing.isEmpty || test != nil else { return }
        if ready, let webView { webView.evaluateJavaScript(code) } else { queued.append(code) }
        if webView == nil { refresh() }
    }

    private func refresh() {
        let need = viewing || stopTimer != nil || !incoming.isEmpty || !outgoing.isEmpty || test != nil
        if need != active { active = need }
        if need, webView == nil { _ = web }
        if !need, webView != nil {  // plus rien ne circule : la page s'en va (et son processus avec)
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "cam")
            webView = nil
            ready = false
            queued = []
        }
    }

    // MARK: Essai sur ce Mac (diagnostic par le socket : EncocheCamTest)

    /// La caméra part par une connexion et revient par une autre, sur ce Mac : caméra, WebRTC et images.
    func selfTest(_ done: @escaping ([String: Any]) -> Void) {
        guard test == nil else { return done(["error": "essai déjà en cours"]) }
        test = done
        refresh()
        func run(_ tries: Int) {  // la page doit d'abord être chargée
            let cam = FriendCam.shared
            guard cam.ready || tries == 0 else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(tries - 1) }
            }
            cam.web.callAsyncJavaScript("return await selfTest()", arguments: [:], in: nil, in: .page) { result in
                MainActor.assumeIsolated {
                    let cam = FriendCam.shared
                    var out: [String: Any] = [:]
                    switch result {
                    case .success(let v): out = v as? [String: Any] ?? ["result": "\(v)"]
                    case .failure(let e): out = ["error": e.localizedDescription]
                    }
                    let finish = cam.test
                    cam.test = nil
                    cam.refresh()
                    finish?(out)
                }
            }
        }
        run(50)
    }

    func diagnose() -> [String: Any] {
        ["viewing": viewing, "active": active, "incoming": Array(incoming), "outgoing": Array(outgoing),
         "frames": Array(Frames.shared.images.keys), "failed": Array(failed), "watchers": Array(watchers.values)]
    }

    // MARK: Outils

    nonisolated static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// Une description de connexion (SDP) fait 2 à 5 Ko : compressée, elle tient dans un message ntfy (4 Ko).
    nonisolated static func pack(_ s: String) -> String {
        ((try? (Data(s.utf8) as NSData).compressed(using: .zlib)) as Data?)?.base64EncodedString() ?? ""
    }

    nonisolated static func unpack(_ s: String?) -> String? {
        guard let s, let data = Data(base64Encoded: s), let raw = try? (data as NSData).decompressed(using: .zlib) else { return nil }
        return String(data: raw as Data, encoding: .utf8)
    }

    static let page = """
    <!doctype html><html><head><meta charset="utf-8"></head>
    <body style="margin:0;overflow:hidden;background:#000"><script>
    'use strict';
    const ICE = [{urls: ['stun:stun.l.google.com:19302', 'stun:stun.cloudflare.com:3478']}];
    const peers = {};
    let cam = null;
    const post = m => window.webkit.messageHandlers.cam.postMessage(m);

    async function camera() {
      if (cam && cam.getVideoTracks().some(t => t.readyState === 'live')) return cam;
      cam = await navigator.mediaDevices.getUserMedia({audio: false,
        video: {width: {ideal: 320}, height: {ideal: 240}, frameRate: {ideal: 12}}});
      return cam;
    }
    function cameraOffIfIdle() {
      if (!cam || Object.keys(peers).some(k => k.startsWith('out:'))) return;
      cam.getTracks().forEach(t => t.stop());
      cam = null;
    }
    function gathered(pc) {
      return new Promise(done => {
        if (pc.iceGatheringState === 'complete') return done();
        const timer = setTimeout(done, 3000);
        pc.addEventListener('icegatheringstatechange', () => {
          if (pc.iceGatheringState === 'complete') { clearTimeout(timer); done(); }
        });
      });
    }
    // H.264 seulement : tous les Mac le décodent, et la description de connexion reste courte.
    function h264(tr) {
      try {
        const keep = RTCRtpSender.getCapabilities('video').codecs
          .filter(c => /H264/i.test(c.mimeType) && /packetization-mode=1/.test(c.sdpFmtpLine || ''));
        if (keep.length) tr.setCodecPreferences(keep.slice(0, 2));
      } catch (e) {}
    }
    // Une connexion coupée plus de 15 s (le pote a fermé son Mac) se ferme, et la caméra avec.
    function follow(key, pc) {
      const mine = () => peers[key] && peers[key].pc === pc;
      let lost = null;
      pc.onconnectionstatechange = () => {
        post({type: 'state', key, state: pc.connectionState});
        clearTimeout(lost);
        if ((pc.connectionState === 'failed' || pc.connectionState === 'closed') && mine()) close(key);
        if (pc.connectionState === 'disconnected') lost = setTimeout(() => { if (mine()) close(key); }, 15000);
      };
    }
    // Un pote veut me voir : ma caméra part vers lui.
    async function offer(id) {
      const key = 'out:' + id;
      close(key);
      try {
        const stream = await camera();
        const pc = new RTCPeerConnection({iceServers: ICE});
        peers[key] = {pc};
        follow(key, pc);
        h264(pc.addTransceiver(stream.getVideoTracks()[0], {direction: 'sendonly', streams: [stream]}));
        await pc.setLocalDescription(await pc.createOffer());
        await gathered(pc);
        if (!peers[key] || peers[key].pc !== pc) return;
        post({type: 'offer', id, sdp: pc.localDescription.sdp});
        // Pas de réponse en 30 s (réseau, pote parti) : une offre sans réponse n'échoue jamais d'elle-même.
        setTimeout(() => { if (peers[key] && peers[key].pc === pc && pc.connectionState !== 'connected') close(key); }, 30000);
      } catch (e) { post({type: 'error', key, message: String(e)}); close(key); }
    }
    async function answered(id, sdp) {
      const p = peers['out:' + id];
      if (!p) return;
      try {
        await p.pc.setRemoteDescription({type: 'answer', sdp});
        const s = p.pc.getSenders()[0], prm = s.getParameters();
        if (prm.encodings && prm.encodings.length) { prm.encodings[0].maxBitrate = 300000; await s.setParameters(prm); }
      } catch (e) { post({type: 'error', key: 'out:' + id, message: String(e)}); }
    }
    // L'image d'un pote arrive : elle est recopiée 10 fois par seconde vers l'encoche.
    async function accept(id, sdp) {
      const key = 'in:' + id;
      close(key);
      const pc = new RTCPeerConnection({iceServers: ICE});
      const video = document.createElement('video');
      video.muted = true; video.playsInline = true; video.autoplay = true;
      video.style.cssText = 'position:absolute;left:0;top:0;width:2px;height:2px';
      document.body.appendChild(video);
      const peer = {pc, video};
      peers[key] = peer;
      follow(key, pc);
      pc.ontrack = e => {
        video.srcObject = e.streams[0] || new MediaStream([e.track]);
        video.play().catch(() => {});
        if (!peer.timer) peer.timer = setInterval(() => grab(id, video), 100);
      };
      try {
        await pc.setRemoteDescription({type: 'offer', sdp});
        await pc.setLocalDescription(await pc.createAnswer());
        await gathered(pc);
        if (peers[key] !== peer) return;
        post({type: 'answer', id, sdp: pc.localDescription.sdp});
      } catch (e) { post({type: 'error', key, message: String(e)}); close(key); }
    }
    const canvas = document.createElement('canvas');
    canvas.width = 192; canvas.height = 144;
    const ctx = canvas.getContext('2d');
    function grab(id, v) {
      if (v.readyState < 2 || !v.videoWidth) return;
      const k = Math.max(canvas.width / v.videoWidth, canvas.height / v.videoHeight);
      const w = v.videoWidth * k, h = v.videoHeight * k;
      ctx.drawImage(v, (canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
      post({type: 'frame', id, data: canvas.toDataURL('image/jpeg', 0.72)});
    }
    function close(key) {
      const p = peers[key];
      if (!p) return;
      delete peers[key];
      clearInterval(p.timer);
      try { p.pc.close(); } catch (e) {}
      if (p.video) { p.video.srcObject = null; p.video.remove(); }
      post({type: 'closed', key});
      if (key.startsWith('out:')) cameraOffIfIdle();
    }
    function closeAll(prefix) { Object.keys(peers).filter(k => k.startsWith(prefix)).forEach(close); }

    async function selfTest() {
      const out = {};
      try {
        const t0 = performance.now();
        const stream = await camera();
        out.camera = true;
        out.cameraMs = Math.round(performance.now() - t0);
        const a = new RTCPeerConnection({iceServers: ICE}), b = new RTCPeerConnection({iceServers: ICE});
        h264(a.addTransceiver(stream.getVideoTracks()[0], {direction: 'sendonly', streams: [stream]}));
        const video = document.createElement('video');
        video.muted = true; video.playsInline = true; video.autoplay = true;
        document.body.appendChild(video);
        b.ontrack = e => { video.srcObject = e.streams[0] || new MediaStream([e.track]); video.play().catch(() => {}); };
        await a.setLocalDescription(await a.createOffer());
        await gathered(a);
        out.offerBytes = a.localDescription.sdp.length;
        out.candidates = (a.localDescription.sdp.match(/a=candidate/g) || []).length;
        out.internetAddress = /typ srflx/.test(a.localDescription.sdp);
        await b.setRemoteDescription(a.localDescription);
        await b.setLocalDescription(await b.createAnswer());
        await gathered(b);
        out.answerBytes = b.localDescription.sdp.length;
        out.offerSdp = a.localDescription.sdp;
        await a.setRemoteDescription(b.localDescription);
        let frames = 0;
        const until = performance.now() + 6000;
        while (performance.now() < until) {
          await new Promise(r => setTimeout(r, 100));
          if (video.readyState >= 2 && video.videoWidth) { grab('selftest', video); frames++; }
        }
        out.frames = frames;
        out.state = a.connectionState;
        out.size = video.videoWidth + 'x' + video.videoHeight;
        a.close(); b.close(); video.remove();
      } catch (e) { out.error = String(e); }
      cameraOffIfIdle();
      out.visibility = document.visibilityState;
      return out;
    }
    </script></body></html>
    """
}

/// La page de la caméra, tenue sous l'encoche noire (invisible, mais dans une fenêtre affichée).
struct CamHost: View {
    @ObservedObject var cam = FriendCam.shared

    var body: some View {
        if cam.active { CamWebView().frame(width: 2, height: 2) }
    }
}

private struct CamWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { FriendCam.shared.web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
