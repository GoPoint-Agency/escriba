import AVFoundation
import CoreMedia

struct Segment {
    let track: String   // "mic" o "sys"
    let start: Double   // segundos desde el inicio de la reunión
    let end: Double
    let url: URL
}

/// Una pista (micrófono o audio del sistema): la guarda completa en disco
/// y la corta en frases usando los silencios, para transcribir mientras se graba.
final class TrackProcessor {
    let track: String
    let dir: URL
    let onSegment: (Segment) -> Void
    private let converter: MonoConverter
    private var archive: AVAudioFile?
    private(set) var position: Int64 = 0
    private var timeOffset: Double?

    // Detección de voz
    private let frameLen = 480                 // 30 ms
    private var frame: [Float] = []
    private var noise: Float = 0.002
    private var inSeg = false
    private var seg: [Float] = []
    private var segStart: Int64 = 0
    private var lastSpeech: Int64 = 0
    private var speechFrames = 0
    private var preroll: [Float] = []
    private let prerollLen = Int(kSR * 0.3)
    private var count = 0

    init(track: String, dir: URL, archive: Bool, firstChannelOnly: Bool, onSegment: @escaping (Segment) -> Void) {
        self.track = track
        self.dir = dir
        self.onSegment = onSegment
        self.converter = MonoConverter(firstChannelOnly: firstChannelOnly)
        if archive {
            self.archive = try? AVAudioFile(forWriting: dir.appendingPathComponent("\(track).caf"),
                                            settings: pcm16Settings(), commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("segmentos"), withIntermediateDirectories: true)
    }

    var archiveURL: URL { dir.appendingPathComponent("\(track).caf") }

    /// `t` = segundos desde el inicio de la reunión en que empieza este buffer.
    func ingest(_ buf: AVAudioPCMBuffer, at t: Double, wallNow: Double) {
        if timeOffset == nil {
            // Si el reloj del buffer no calza con el reloj real, se corrige una vez.
            timeOffset = abs(t - wallNow) > 2 ? (wallNow - t) : 0
        }
        let at = t + (timeOffset ?? 0)
        let samples = converter.convert(buf)
        if samples.isEmpty { return }
        let expected = Int64(max(0, at) * kSR)
        let gap = expected - position
        if gap > Int64(kSR * 0.2) {
            let n = Int(min(gap, Int64(kSR * 3600 * 4)))
            append([Float](repeating: 0, count: n))
        }
        append(samples)
    }

    func append(_ samples: [Float]) {
        if let archive, let b = makeBuffer(samples) { try? archive.write(from: b) }
        for s in samples {
            frame.append(s)
            if frame.count == frameLen {
                processFrame(frame, startIndex: position + Int64(count) - Int64(frameLen) + 1)
                frame.removeAll(keepingCapacity: true)
            }
            count += 1
        }
        position += Int64(samples.count)
        count = 0
    }

    private func processFrame(_ f: [Float], startIndex idx: Int64) {
        var sum: Float = 0
        for x in f { sum += x * x }
        let rms = (sum / Float(f.count)).squareRoot()
        let thr = max(noise * 3.5, 0.006)
        let speech = rms > thr
        if !speech {
            noise = rms < noise ? noise * 0.9 + rms * 0.1 : min(noise * 1.002, 0.05)
            noise = max(noise, 0.0005)
        }
        let end = idx + Int64(f.count)
        if inSeg {
            seg.append(contentsOf: f)
            if speech { lastSpeech = end; speechFrames += 1 }
            let segLen = Double(seg.count) / kSR
            let silence = Double(end - lastSpeech) / kSR
            if (silence >= 0.8 && segLen >= 1.5) || (segLen >= 25 && silence >= 0.25) || segLen >= 55 {
                closeSegment()
            }
        } else if speech {
            inSeg = true
            seg = preroll + f
            segStart = idx - Int64(preroll.count)
            lastSpeech = end
            speechFrames = 1
            preroll.removeAll()
        } else {
            preroll.append(contentsOf: f)
            if preroll.count > prerollLen { preroll.removeFirst(preroll.count - prerollLen) }
        }
    }

    private func closeSegment() {
        defer { inSeg = false; seg.removeAll(); speechFrames = 0 }
        guard speechFrames >= 8 else { return }   // menos de 0,24 s de voz: ruido
        let keep = min(seg.count, Int(lastSpeech - segStart) + Int(kSR * 0.3))
        let samples = Array(seg.prefix(keep))
        let start = Double(segStart) / kSR
        let url = dir.appendingPathComponent("segmentos/\(track)_\(String(format: "%08d", Int(start * 1000))).wav")
        do {
            try writeWAV(samples, to: url)
            onSegment(Segment(track: track, start: start, end: start + Double(samples.count) / kSR, url: url))
        } catch {
            log("No pude guardar el segmento \(url.lastPathComponent): \(error)")
        }
    }

    func flush() {
        if inSeg { closeSegment() }
        archive = nil   // cierra el archivo
    }
}
