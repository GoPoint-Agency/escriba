import AVFoundation
import AppKit
import ScreenCaptureKit

/// Traducción en vivo con OpenAI (gpt-realtime-translate): entra el audio de la reunión, sale voz en español.
let kTR: Double = 24000
let mono24k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kTR, channels: 1, interleaved: false)!

/// Convierte cualquier buffer a mono Float32 (24 kHz si no se indica otra cosa).
final class Mono24Converter {
    private var conv: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let mono24k: AVAudioFormat
    private let kTR: Double

    init(to format: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!) {
        mono24k = format
        kTR = format.sampleRate
    }

    func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        let fmt = buf.format
        if conv == nil || inFormat != fmt {
            conv = AVAudioConverter(from: fmt, to: mono24k)
            conv?.downmix = true
            inFormat = fmt
        }
        guard let conv else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * kTR / fmt.sampleRate + 2048)
        guard let out = AVAudioPCMBuffer(pcmFormat: mono24k, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        let st = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if st == .error { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// La conexión con OpenAI. Se le manda audio sin parar (también el silencio) y devuelve voz y texto traducidos.
final class TranslateSocket {
    static let model = "gpt-realtime-translate"
    static let dollarsPerMinute = 0.034
    static let chunk = Int(kTR * (Double(ProcessInfo.processInfo.environment["ESCRIBA_TROZO_MS"] ?? "") ?? 200) / 1000)   // 200 ms

    var onAudio: (([Float]) -> Void)?
    var onText: ((String) -> Void)?
    var onSource: ((String) -> Void)?
    /// La conexión terminó sola. Trae el motivo en palabras simples.
    var onDropped: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let q = DispatchQueue(label: "escriba.traductor.socket")
    private var created = false
    private var ready: CheckedContinuation<Void, Error>?
    private var closing = false
    private var finished = false
    private var seen = Set<String>()
    private var closedWaiter: CheckedContinuation<Void, Never>?

    func connect(language: String, sourceTranscript: Bool = false) async throws {
        guard let key = Config.apiKey else { throw EscribaError.noKey }
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime/translations?model=\(TranslateSocket.model)")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        listen()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            q.async {
                if self.created { c.resume() } else if self.finished { c.resume(throwing: EscribaError.other("No pude conectarme con OpenAI")) } else { self.ready = c }
            }
            q.asyncAfter(deadline: .now() + 15) { self.failReady(EscribaError.other("OpenAI no respondió a tiempo. Revisa internet.")) }
        }
        var session: [String: Any] = ["audio": ["output": ["language": language]]]
        if sourceTranscript {
            session = ["audio": ["output": ["language": language], "input": ["transcription": ["model": "gpt-realtime-whisper"]]]]
        }
        send(["type": "session.update", "session": session])
    }

    private func failReady(_ e: Error) {
        if let r = ready { ready = nil; r.resume(throwing: e) }
    }

    /// Exactamente 200 ms de audio mono a 24 kHz.
    func append(_ samples: [Float]) {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
        }
        send(["type": "session.input_audio_buffer.append", "audio": d.base64EncodedString()])
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                switch result {
                case .failure(let e):
                    self.finish(self.closing ? nil : "Se cortó la conexión con OpenAI: \(e.localizedDescription)")
                case .success(let m):
                    var text: String?
                    switch m {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let text { self.handle(text) }
                    if !self.finished { self.listen() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = j["type"] as? String else { return }
        switch type {
        case "session.created":
            created = true
            if let r = ready { ready = nil; r.resume() }
        case "session.output_audio.delta":
            guard let b64 = j["delta"] as? String, let d = Data(base64Encoded: b64), d.count >= 2 else { return }
            var out = [Float](repeating: 0, count: d.count / 2)
            d.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<out.count { out[i] = Float(Int16(littleEndian: p[i])) / 32768 }
            }
            onAudio?(out)
        case "session.output_transcript.delta":
            if let t = j["delta"] as? String { onText?(t) }
        case "session.input_transcript.delta":
            if let t = j["delta"] as? String { onSource?(t) }
        case "session.closed":
            finish(closing ? nil : "OpenAI cerró la traducción.")
        case "error":
            let e = j["error"] as? [String: Any]
            let msg = (e?["message"] as? String) ?? text
            log("Traducción, error de OpenAI: \(msg)")
            if ready != nil { failReady(EscribaError.other("OpenAI rechazó la traducción: \(msg.prefix(200))")) }
        default:
            if ProcessInfo.processInfo.environment["ESCRIBA_EVENTOS"] != nil, !seen.contains(type) { seen.insert(type); print("evento: \(text.prefix(400))") }
        }
    }

    private func finish(_ problem: String?) {
        guard !finished else { return }
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        failReady(EscribaError.other(problem ?? "No pude conectarme con OpenAI"))
        if let w = closedWaiter { closedWaiter = nil; w.resume() }
        if let problem, !closing { onDropped?(problem) }
    }

    /// Cierra con aviso para que OpenAI entregue lo último que estaba traduciendo.
    func close() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.async {
                if self.finished { c.resume(); return }
                self.closing = true
                self.closedWaiter = c
                self.send(["type": "session.close"])
                self.q.asyncAfter(deadline: .now() + 3) { self.finish(nil) }
            }
        }
    }
}

/// Toma el audio del sistema (lo que dicen los demás), lo traduce y lo reproduce en los audífonos.
final class LiveTranslator: NSObject, SCStreamOutput, SCStreamDelegate {
    static let idleLimit: TimeInterval = 600   // 10 minutos sin que nadie hable: se detiene sola

    private let socket = TranslateSocket()
    private lazy var feeder = Feeder(socket: socket)
    private let playout = Playout(speedUp: Config.catchUp)
    private let meter = LatencyMeter()
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private var voiceNode: AVAudioSourceNode?
    private let queue = DispatchQueue(label: "escriba.traductor")
    private let screenQueue = DispatchQueue(label: "escriba.traductor.pantalla")
    private let conv = Mono24Converter()
    private var tapStop: (() -> Void)?
    private var ring: AudioRing?
    private var passthrough: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    /// El audio original se silenció y Escriba lo reproduce más bajo.
    private(set) var ducking = false
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var stopped = false
    private var chars = 0
    private var testText = ""
    private(set) var startDate = Date()
    /// Texto traducido, a medida que llega.
    var onText: ((String) -> Void)?
    /// Se detuvo sola (corte o silencio largo). Trae el motivo.
    var onAutoStop: ((String) -> Void)?

    func start(language: String) async throws {
        let p = playout
        socket.onAudio = { p.push($0) }
        socket.onText = { [weak self] t in DispatchQueue.main.async { self?.chars += t.count; self?.testText += t; self?.onText?(t) } }
        socket.onDropped = { [weak self] m in self?.autoStop(m) }
        try await socket.connect(language: language)
        do {
            // La voz traducida sale por aquí: el audio le pide a la cola lo que toca sonar en cada instante.
            let node = AVAudioSourceNode(format: mono24k) { _, _, frames, abl -> OSStatus in
                let l = UnsafeMutableAudioBufferListPointer(abl)
                if let out = l[0].mData?.assumingMemoryBound(to: Float.self) { p.pull(out, Int(frames)) }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono24k)
            voiceNode = node
            try engine.start()
            if !startTap() { try await startSystemAudio() }
        } catch {
            engine.stop()
            await socket.close()
            throw EscribaError.other("No pude capturar el audio de la reunión. Revisa el permiso de Grabación de pantalla y audio del sistema. (\(error.localizedDescription))")
        }
        // Si cambia la salida (por ejemplo, se conectan audífonos), el motor de audio se detiene: hay que reanudarlo.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, !self.stopped else { return }
            log("Traducción: cambió la salida de audio")
            if self.ducking {
                self.autoStop("Cambió la salida de audio. Vuelve a activar la traducción.")
            } else {
                try? self.engine.start()
            }
        })
        startDate = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated, .latencyCritical], reason: "Traduciendo una reunión")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
        log("Traducción en vivo activa (\(language))")
    }

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw EscribaError.other("No encontré pantalla") }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true   // la voz traducida no vuelve a entrar
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let st = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try st.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await st.startCapture()
        stream = st
    }

    /// Captura que además baja el volumen del original (macOS 14.2 o más nuevo). Si no se puede, se usa la otra.
    private func startTap() -> Bool {
        guard #available(macOS 14.2, *), Config.originalVolume < 0.99 else { return false }
        let tap = SystemTap(queue: queue)
        do {
            try tap.start(mute: true)
            guard let fmt = tap.format,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false) else {
                tap.stop(); return false
            }
            let r = AudioRing(sampleRate: fmt.sampleRate)
            let idle = Float(max(0, Config.originalVolume)), ducked = Float(max(0, Config.originalVolumeDucked))
            r.setLevels(idle: idle, ducked: ducked, immediately: true)
            let p = playout
            // El original suena bajo, y más bajo todavía mientras habla la traducción.
            let node = AVAudioSourceNode(format: mono) { _, _, frames, abl -> OSStatus in
                let l = UnsafeMutableAudioBufferListPointer(abl)
                if let out = l[0].mData?.assumingMemoryBound(to: Float.self) { r.read(out, Int(frames), ducked: p.speaking) }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            let toMono = Mono24Converter(to: mono)
            tap.onBuffer = { [weak self] b in
                r.write(toMono.convert(b))
                self?.ingest(b)
            }
            ring = r
            passthrough = node
            tapStop = { tap.stop() }
            ducking = true
            log("Traducción: el audio original queda al \(Int(idle * 100)) % y baja al \(Int(ducked * 100)) % mientras suena la traducción")
            return true
        } catch {
            log("Traducción: no pude bajar el volumen del original, sigo sin eso: \(error.localizedDescription)")
            tap.stop()
            return false
        }
    }

    /// Cambia el volumen del original en plena traducción.
    func setOriginalLevels(idle: Double, ducked: Double) {
        ring?.setLevels(idle: Float(idle), ducked: Float(ducked))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let pcm = sb.toPCMBuffer() else { return }
        ingest(pcm)
    }

    private func ingest(_ pcm: AVAudioPCMBuffer) {
        feeder.ingest(conv.convert(pcm))
    }

    private func pump() {
        feeder.tick()
        meter.tick(lastSpeech: feeder.lastSpeech, sinceLoudOut: playout.sinceLoudOut)
        if Date().timeIntervalSince(max(feeder.lastSpeech, startDate)) > LiveTranslator.idleLimit {
            autoStop("Pasaron 10 minutos sin que nadie hablara, así que detuve la traducción.")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("La captura para traducir se detuvo: \(error)")
        autoStop("Se cortó la captura del audio de la reunión: \(error.localizedDescription)")
    }

    private func autoStop(_ reason: String) {
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            Task { @MainActor in
                await self.stop()
                self.onAutoStop?(reason)
            }
        }
    }

    func stop() async {
        if stopped { return }
        stopped = true
        timer?.cancel()
        timer = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        tapStop?()   // lo primero: las demás apps vuelven a sonar normal
        tapStop = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        let (speech, delay) = queue.sync { (feeder.speechSeconds, meter.summary) }
        let st = playout.snapshot   // antes de cerrar: al cerrar, OpenAI vacía de golpe varios segundos de silencio
        await socket.close()
        engine.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        log("Traducción en vivo detenida a los \(reloj(Date().timeIntervalSince(startDate))): \(Int(speech)) s de voz original, \(Int(Double(st.loudOut) / kTR)) s de voz traducida, \(chars) letras")
        log("Traducción en vivo, retraso: \(delay ?? "sin frases que medir"). \(Playout.describe(st))")
        if ProcessInfo.processInfo.environment["ESCRIBA_PRUEBA"] != nil { log("Texto de prueba: \(testText)") }
    }
}

/// Subtítulos flotantes con lo último traducido. No aparecen si compartes pantalla.
final class CaptionPanel {
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var text = ""

    func show() {
        if panel == nil { build() }
        text = ""
        label.stringValue = "Traduciendo… habla alguien en la reunión y aquí aparece en español."
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func append(_ delta: String) {
        text += delta
        if text.count > 150 {
            let tail = String(text.suffix(110))
            text = tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? tail
        }
        label.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func build() {
        let w: CGFloat = 720, h: CGFloat = 96
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let p = NSPanel(contentRect: NSRect(x: screen.midX - w / 2, y: screen.minY + 60, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.material = .hudWindow
        box.state = .active
        box.blendingMode = .behindWindow
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        p.contentView = box
        panel = p
    }
}

/// Prueba sin reunión: traduce un archivo de audio y guarda la voz traducida.
enum TranslateTest {
    static func run(input: URL, output: URL, language: String) async throws {
        let file = try AVAudioFile(forReading: input)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw EscribaError.other("No pude leer el audio")
        }
        try file.read(into: buf)
        let samples = Mono24Converter().convert(buf)
        let onset = Double(samples.firstIndex(where: { abs($0) > 0.02 }) ?? 0) / kTR
        let last = Double(samples.lastIndex(where: { abs($0) > 0.02 }) ?? 0) / kTR
        print("Entrada: \(String(format: "%.1f", Double(samples.count) / kTR)) s; voz entre \(String(format: "%.1f", onset)) y \(String(format: "%.1f", last)) s")
        let socket = TranslateSocket()
        let lock = NSLock()
        var out: [Float] = []
        var text = "", source = ""
        var firstAudio: Date?
        var firstLoud: Date?, lastLoud: Date?, maxAhead = -1e9
        var leadMax = -1e9, leadLast = 0.0, deltas = 0
        var sendStart = Date()
        var arrivals: [(Double, Int)] = []   // (segundos desde que se empezó a enviar, muestras recibidas hasta ahí)
        let pace = Double(ProcessInfo.processInfo.environment["ESCRIBA_RITMO"] ?? "") ?? 1   // 2 = el doble de rápido que el tiempo real
        socket.onAudio = { s in
            lock.lock()
            if firstAudio == nil { firstAudio = Date() }
            out += s
            if s.contains(where: { abs($0) > 0.02 }) {
                if firstLoud == nil { firstLoud = Date() }; lastLoud = Date()
                let lead = Double(out.count) / kTR - Date().timeIntervalSince(firstAudio!)
                leadMax = max(leadMax, lead); leadLast = lead
            }
            deltas += 1
            arrivals.append((Date().timeIntervalSince(sendStart), out.count))
            maxAhead = max(maxAhead, Double(out.count) / kTR - Date().timeIntervalSince(sendStart))
            lock.unlock()
        }
        socket.onText = { t in lock.lock(); text += t; lock.unlock() }
        socket.onSource = { t in lock.lock(); source += t; lock.unlock() }
        socket.onDropped = { m in print("Corte: \(m)") }
        let t0 = Date()
        try await socket.connect(language: language, sourceTranscript: true)
        print("Conectado en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let n = TranslateSocket.chunk
        let tail = Double(ProcessInfo.processInfo.environment["ESCRIBA_COLA_S"] ?? "") ?? 6
        let total = samples + [Float](repeating: 0, count: Int(kTR * tail))
        sendStart = Date()
        var i = 0
        while i + n <= total.count {
            socket.append(Array(total[i..<(i + n)]))
            i += n
            // Ritmo exacto: se espera hasta la hora que le toca al siguiente trozo, sin acumular desvío.
            let due = sendStart.addingTimeInterval(Double(i) / kTR / pace)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        let sentAll = Date().timeIntervalSince(sendStart)
        await socket.close()
        let closedAt = Date().timeIntervalSince(sendStart)
        lock.lock(); defer { lock.unlock() }
        if let f = firstLoud, let l = lastLoud { print("Voz: llega entre \(String(format: "%.1f", f.timeIntervalSince(sendStart))) s y \(String(format: "%.1f", l.timeIntervalSince(sendStart))) s; adelanto máximo del audio recibido \(String(format: "%.1f", maxAhead)) s") }
        print("Adelanto del audio con voz respecto de tiempo real: máximo \(String(format: "%.2f", leadMax)) s, al final \(String(format: "%.2f", leadLast)) s; \(deltas) entregas")
        if let f = firstAudio { print("Primera voz traducida a los \(String(format: "%.1f", f.timeIntervalSince(sendStart))) s de empezar") }
        print("Original: \(source)")
        print("Traducción: \(text)")
        print("Voz traducida: \(String(format: "%.1f", Double(out.count) / kTR)) s")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: kTR, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if !out.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: mono24k, frameCapacity: AVAudioFrameCount(out.count)) {
            b.frameLength = AVAudioFrameCount(out.count)
            out.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
            try f.write(from: b)
        }
        print("Guardado: \(output.path)")
        let csv = arrivals.map { "\(String(format: "%.3f", $0.0)),\($0.1)" }.joined(separator: "\n")
        try? ("llegada_s,muestras\n" + csv + "\n").write(to: output.appendingPathExtension("csv"), atomically: true, encoding: .utf8)
        print("Ritmo \(pace)x; envío terminado a los \(String(format: "%.1f", sentAll)) s; cierre a los \(String(format: "%.1f", closedAt)) s")
    }
}

/// Prueba completa sin reunión: simula en tiempo real la captura de un archivo, lo manda con el alimentador,
/// pasa la respuesta por la cola de reproducción y guarda exactamente lo que se habría escuchado, segundo a segundo.
enum TranslateSim {
    static func run(input: URL, output: URL, language: String) async throws {
        let env = ProcessInfo.processInfo.environment
        let fast = (env["ESCRIBA_RAPIDA"] ?? "1") != "0"
        let tailSeconds = Double(env["ESCRIBA_COLA_S"] ?? "") ?? 8
        let file = try AVAudioFile(forReading: input)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw EscribaError.other("No pude leer el audio")
        }
        try file.read(into: buf)
        let samples = Mono24Converter().convert(buf) + [Float](repeating: 0, count: Int(kTR * tailSeconds))
        let socket = TranslateSocket()
        let feeder = Feeder(socket: socket)
        let playout = Playout(speedUp: fast)
        let meter = LatencyMeter()
        let lock = NSLock()
        var text = ""
        var rawOut: [Float] = []
        var arrivals: [(Double, Int)] = []
        var t0 = Date()
        socket.onAudio = { s in
            playout.push(s)
            lock.lock(); rawOut += s; arrivals.append((Date().timeIntervalSince(t0), rawOut.count)); lock.unlock()
        }
        socket.onText = { t in lock.lock(); text += t; lock.unlock() }
        socket.onDropped = { m in print("Corte: \(m)") }
        try await socket.connect(language: language)
        // Reloj de 10 ms: entra audio «capturado» y sale lo que sonaría.
        let block = 240
        var heard = [Float](repeating: 0, count: samples.count)
        let start = Date()
        lock.lock(); t0 = start; lock.unlock()
        var k = 0
        let total = samples.count / block
        while k < total {
            let due = start.addingTimeInterval(Double(k) * 0.01)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            feeder.ingest(Array(samples[(k * block)..<((k + 1) * block)]))
            heard.withUnsafeMutableBufferPointer { p in playout.pull(p.baseAddress! + k * block, block) }
            if k % 5 == 0 { feeder.tick(); meter.tick(lastSpeech: feeder.lastSpeech, sinceLoudOut: playout.sinceLoudOut) }
            k += 1
        }
        let st = playout.snapshot
        await socket.close()
        lock.lock(); defer { lock.unlock() }
        func save(_ s: [Float], _ url: URL) throws {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: kTR, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard !s.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: mono24k, frameCapacity: AVAudioFrameCount(s.count)) else { return }
            b.frameLength = AVAudioFrameCount(s.count)
            s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
            try f.write(from: b)
        }
        try save(heard, output)
        try save(rawOut, output.deletingPathExtension().appendingPathExtension("crudo.wav"))
        print("Traducción: \(text)")
        print(String(format: "Enviado %.1f s (%.1f s con voz) para %.1f s reales", feeder.sentSeconds, feeder.speechSeconds, Double(samples.count) / kTR))
        print("Medidor: \(meter.summary ?? "sin datos")")
        print(Playout.describe(st))
        let base = output.deletingPathExtension()
        try? ("llegada_s,muestras\n" + arrivals.map { String(format: "%.3f,%d", $0.0, $0.1) }.joined(separator: "\n") + "\n")
            .write(to: base.appendingPathExtension("llegadas.csv"), atomically: true, encoding: .utf8)

    }
}

/// Repite una traza grabada por el simulador (qué audio llegó y cuándo) con otra forma de reproducirlo.
/// Sirve para comparar colas de reproducción sobre exactamente la misma respuesta de OpenAI.
enum TraceReplay {
    static func run(base: URL, output: URL, mode: String) throws {
        let env = ProcessInfo.processInfo.environment
        let file = try AVAudioFile(forReading: base.appendingPathExtension("crudo.wav"))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
        try file.read(into: buf)
        let raw = Mono24Converter().convert(buf)
        func rows(_ ext: String) -> [[Double]] {
            guard let t = try? String(contentsOf: base.appendingPathExtension(ext), encoding: .utf8) else { return [] }
            return t.split(separator: "\n").dropFirst().map { $0.split(separator: ",").compactMap { Double($0) } }
        }
        let arrivals = rows("llegadas.csv")      // segundo, muestras acumuladas
        let total = Int(((arrivals.last?[0] ?? 0) + 2) * 100)
        var heard = [Float](repeating: 0, count: total * 240)
        var ai = 0, pos = 0
        var summary = ""
        if mode == "anterior" {
            // La cola de antes: cada entrega se agenda apenas llega y solo se descarta silencio con más de 0,8 s acumulados.
            var queuedUntil = 0.0
            for a in arrivals {
                let now = a[0], end = min(raw.count, Int(a[1]))
                let chunk = Array(raw[pos..<end]); pos = end
                if queuedUntil < now { queuedUntil = now }
                if queuedUntil - now > 0.8, !Playout.isLoud(chunk, 0.003) { continue }
                let at = Int(queuedUntil * kTR)
                for (i, v) in chunk.enumerated() where at + i < heard.count { heard[at + i] = v }
                queuedUntil += Double(chunk.count) / kTR
            }
            summary = "cola anterior"
        } else {
            let p = Playout(speedUp: mode == "rapida", cushion: Double(env["ESCRIBA_COLCHON_MS"] ?? "").map { $0 / 1000 } ?? 0.25,
                            adaptive: (env["ESCRIBA_COLCHON_FIJO"] ?? "0") == "0")
            if let m = env["ESCRIBA_VEL_MAX"], let v = Double(m) { p.maxRate = v }
            for k in 0..<total {
                let t = Double(k) * 0.01
                while ai < arrivals.count, arrivals[ai][0] <= t {
                    let end = min(raw.count, Int(arrivals[ai][1]))
                    if end > pos { p.push(Array(raw[pos..<end])) }
                    pos = end; ai += 1
                }
                heard.withUnsafeMutableBufferPointer { b in p.pull(b.baseAddress! + k * 240, 240) }
            }
            summary = Playout.describe(p.snapshot)
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: kTR, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let f = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if let b = AVAudioPCMBuffer(pcmFormat: mono24k, frameCapacity: AVAudioFrameCount(heard.count)) {
            b.frameLength = AVAudioFrameCount(heard.count)
            heard.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: heard.count) }
            try f.write(from: b)
        }
        print("\(mode): \(summary)")
    }
}
