import AVFoundation
import SwiftUI

/// Miroir : la caméra du Mac, en miroir, pour vérifier sa tête avant une visio. La caméra ne s'allume
/// que tant que le miroir est affiché.
struct MirrorView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraView { CameraView() }
    func updateNSView(_ v: CameraView, context: Context) {}
    static func dismantleNSView(_ v: CameraView, coordinator: ()) { v.stop() }
}

final class CameraView: NSView {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private let queue = DispatchQueue(label: "encoche.camera")
    var denied: ((Bool) -> Void)?

    override init(frame: NSRect) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.queue.async { self.configure() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        session.commitConfiguration()
        DispatchQueue.main.async {
            if let c = self.preview.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
        }
        session.startRunning()
    }

    func stop() { queue.async { self.session.stopRunning() } }
}
