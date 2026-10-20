import AVFoundation

// Sons de synthèse, repris de la bibliothèque Snd des prototypes : chaque son est rendu
// une fois en mémoire au démarrage, puis joué instantanément.

final class Sound {
    static let shared = Sound()

    private struct Tone {
        var f = 440.0, to = 0.0, d = 0.2, triangle = false, g = 0.1, a = 0.006, delay = 0.0
        var vib = 0.0, vibf = 6.0, h = 0.0
    }
    private struct Noise { var d = 0.2, g = 0.04, f = 1500.0, to = 0.0, q = 0.9, delay = 0.0 }

    private let rate = 44_100.0
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var started = false
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

    var on: Bool {
        get { UserDefaults.standard.object(forKey: "sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sound") }
    }

    private init() {
        let lib: [String: ([Tone], [Noise])] = [
            "peek": ([Tone(f: 1320, d: 0.09, g: 0.04), Tone(f: 1760, d: 0.12, g: 0.035, delay: 0.07)], []),
            "open": ([Tone(f: 300, to: 560, d: 0.24, g: 0.06)], [Noise(d: 0.28, g: 0.018, f: 900, to: 3200)]),
            "close": ([Tone(f: 540, to: 300, d: 0.2, g: 0.05)], [Noise(d: 0.2, g: 0.014, f: 2600, to: 800)]),
            "hover": ([Tone(f: 2100, d: 0.05, g: 0.014)], []),
            "blip": ([Tone(f: 1480, d: 0.07, g: 0.035)], []),
            "slap": ([Tone(f: 280, to: 110, d: 0.18, triangle: true, g: 0.16)], [Noise(d: 0.06, g: 0.06, f: 900, q: 0.6)]),
            "annoyed": ([Tone(f: 240, to: 185, d: 0.2, triangle: true, g: 0.07, delay: 0.06)], []),
            "dizzy": ([Tone(f: 640, to: 380, d: 1, g: 0.06, vib: 45, vibf: 9), Tone(f: 960, to: 560, d: 1, g: 0.025, delay: 0.06, vib: 70, vibf: 7)], []),
            "greet": ([523.25, 659.25, 783.99].enumerated().map { Tone(f: $1, d: 0.32, g: 0.06, delay: Double($0) * 0.085, h: 4) }, []),
            "work": ([Tone(f: 880, d: 0.14, g: 0.028), Tone(f: 1174.7, d: 0.18, g: 0.022, delay: 0.07)], []),
            "finish": ([Tone(f: 783.99, d: 0.6, g: 0.08, h: 4), Tone(f: 1046.5, d: 0.9, g: 0.08, delay: 0.11, h: 4),
                        Tone(f: 1318.5, d: 1.1, g: 0.045, delay: 0.22, h: 3)], []),
            "error": ([Tone(f: 392, d: 0.35, triangle: true, g: 0.09), Tone(f: 311.1, d: 0.55, triangle: true, g: 0.09, delay: 0.16)], []),
            "approval": ([Tone(f: 987.8, d: 0.35, g: 0.07, h: 2.76), Tone(f: 987.8, d: 0.5, g: 0.07, delay: 0.18, h: 2.76)], []),
            "question": ([Tone(f: 659.3, d: 0.24, g: 0.06, h: 3), Tone(f: 880, d: 0.4, g: 0.06, delay: 0.12, h: 3)], []),
            "approve": ([Tone(f: 660, d: 0.18, g: 0.05), Tone(f: 990, d: 0.3, g: 0.05, delay: 0.08, h: 3)], []),
            "gulp": ([Tone(f: 340, to: 120, d: 0.16, g: 0.11), Tone(f: 210, to: 80, d: 0.22, g: 0.09, delay: 0.1)], []),
            "tick": ([Tone(f: 2400, d: 0.03, g: 0.012)], []),
            "pop": ([Tone(f: 480, to: 1150, d: 0.11, g: 0.07)], []),
            "love": ([Tone(f: 1046.5, d: 0.32, g: 0.045, vib: 14, vibf: 8), Tone(f: 1318.5, d: 0.5, g: 0.045, delay: 0.14, vib: 14, vibf: 8)], []),
            "proud": ([784, 988, 1175, 1568].enumerated().map { Tone(f: $1, d: 0.4, g: 0.045, delay: Double($0) * 0.06, h: 4) }, []),
            "sleep": ([Tone(f: 330, to: 290, d: 0.5, g: 0.03)], []),
        ]
        for (name, (tones, noises)) in lib { buffers[name] = render(tones, noises) }
    }

    func play(_ name: String) {
        guard on, let buffer = buffers[name] else { return }
        if !started {
            for _ in 0..<6 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
            engine.mainMixerNode.outputVolume = 0.8
            do { try engine.start() } catch { return }
            started = true
        }
        let p = players[next % players.count]
        next += 1
        p.stop()
        p.scheduleBuffer(buffer, at: nil)
        p.play()
    }

    private func render(_ tones: [Tone], _ noises: [Noise]) -> AVAudioPCMBuffer {
        let length = (tones.map { $0.delay + $0.d } + noises.map { $0.delay + $0.d }).max()! + 0.08
        let n = Int(length * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n { out[i] = 0 }

        func envelope(_ t: Double, _ g: Double, _ a: Double, _ d: Double) -> Double {
            if t < 0 || t > d { return 0 }
            if t < a { return 0.0001 * pow(g / 0.0001, t / a) }
            return g * pow(0.0001 / g, (t - a) / (d - a))
        }
        for tone in tones {
            var phase = 0.0, phase2 = 0.0
            let start = Int(tone.delay * rate), count = Int(tone.d * rate)
            for i in 0..<count where start + i < n {
                let t = Double(i) / rate
                var f = tone.f
                if tone.to > 0 { f = tone.f * pow(tone.to / tone.f, min(1, t / (tone.d * 0.9))) }
                if tone.vib > 0 { f += tone.vib * sin(2 * .pi * tone.vibf * t) }
                phase += 2 * .pi * f / rate
                var v = tone.triangle ? 2 / .pi * asin(sin(phase)) : sin(phase)
                v *= envelope(t, tone.g, tone.a, tone.d)
                if tone.h > 0 {
                    phase2 += 2 * .pi * tone.f * tone.h / rate
                    v += sin(phase2) * envelope(t, tone.g * 0.3, tone.a, tone.d * 0.35)
                }
                out[start + i] += Float(v)
            }
        }
        for noise in noises {
            // bruit blanc filtré passe-bande (biquad), fréquence qui glisse
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            let start = Int(noise.delay * rate), count = Int(noise.d * rate)
            for i in 0..<count where start + i < n {
                let t = Double(i) / rate
                let f = noise.to > 0 ? noise.f * pow(noise.to / noise.f, t / noise.d) : noise.f
                let w0 = 2 * .pi * f / rate, alpha = sin(w0) / (2 * noise.q)
                let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
                let x = Double.random(in: -1...1)
                let y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = x; y2 = y1; y1 = y
                let env = t < noise.d * 0.35 ? 0.0001 * pow(noise.g / 0.0001, t / (noise.d * 0.35))
                                             : noise.g * pow(0.0001 / noise.g, (t - noise.d * 0.35) / (noise.d * 0.65))
                out[start + i] += Float(y * env)
            }
        }
        return buf
    }
}
