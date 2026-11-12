import AVFoundation
import AppKit
import CoreAudio
import CoreMedia
import ScreenCaptureKit

struct Utterance: Codable {
    let track: String
    let start: Double
    let end: Double
    let text: String
}

/// Transcribe los segmentos a medida que llegan, de a 3 en paralelo, con reintentos.
actor TranscriptionQueue {
    private(set) var results: [Utterance] = []
    private(set) var failed: [Segment] = []
    private var waiting: [Segment] = []
    private var inFlight = 0
    private var lastText: [String: String] = [:]
    private let logURL: URL
    private let maxConcurrent = Config.isLocal ? 1 : 4

    init(logURL: URL) { self.logURL = logURL }

    func enqueue(_ s: Segment) {
        waiting.append(s)
        pump()
    }

    var pendingCount: Int { waiting.count + inFlight }

    private func pump() {
        while inFlight < maxConcurrent, !waiting.isEmpty {
            let s = waiting.removeFirst()
            inFlight += 1
            Task { await self.run(s) }
        }
    }

    private func run(_ s: Segment) async {
        let context = String((lastText[s.track] ?? "").suffix(200))
        let prompt = [Engine.vocabularyPrompt, context.isEmpty ? nil : context].compactMap { $0 }.joined(separator: " ")
        var text: String?
        for attempt in 0..<4 {
            do { text = try await Engine.transcribe(file: s.url, prompt: prompt); break } catch {
                log("Falló transcripción \(s.url.lastPathComponent) intento \(attempt + 1): \(error.localizedDescription)")
                if case EscribaError.noKey = error { break }
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 2_000_000_000))
            }
        }
        if let t = text {
            if !TextClean.isHallucination(t) {
                let u = Utterance(track: s.track, start: s.start, end: s.end, text: t)
                results.append(u)
                lastText[s.track] = t
                if let d = try? JSONEncoder().encode(u), let h = try? FileHandle(forWritingTo: logURL) {
                    h.seekToEndOfFile(); h.write(d); h.write(Data("\n".utf8)); try? h.close()
                } else if let d = try? JSONEncoder().encode(u) {
                    try? (d + Data("\n".utf8)).write(to: logURL)
                }
            }
            try? FileManager.default.removeItem(at: s.url)
        } else {
            failed.append(s)
        }
        inFlight -= 1
        pump()
    }

    func drain() async {
        while inFlight > 0 || !waiting.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    /// Último intento con lo que falló (por ejemplo, si se cortó internet).
    func retryFailed() async {
        let f = failed
        failed = []
        for s in f { enqueue(s) }
        await drain()
    }
}

/// Una reunión: dos pistas, su transcripción y el documento final.
final class MeetingSession {
    let id: String
    let dir: URL
    let startDate: Date
    let queue = DispatchQueue(label: "escriba.audio")
    let transcriber: TranscriptionQueue
    var mic: TrackProcessor!
    var sys: TrackProcessor!

    init(startDate: Date = Date(), archive: Bool = true) {
        self.startDate = startDate
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        id = f.string(from: startDate)
        dir = Config.sessionsDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = ["inicio": ISO8601DateFormatter().string(from: startDate)]
        try? JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        transcriber = TranscriptionQueue(logURL: dir.appendingPathComponent("transcripcion.jsonl"))
        let t = transcriber
        mic = TrackProcessor(track: "mic", dir: dir, archive: archive, firstChannelOnly: true) { s in Task { await t.enqueue(s) } }
        sys = TrackProcessor(track: "sys", dir: dir, archive: archive, firstChannelOnly: false) { s in Task { await t.enqueue(s) } }
    }

    // MARK: Resultado

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    /// Si el micrófono captó lo que salía por los parlantes, esa frase ya está en la pista de los demás.
    static func dedupe(_ utts: [Utterance]) -> [Utterance] {
        let sys = utts.filter { $0.track == "sys" }
        return utts.filter { u in
            guard u.track == "mic" else { return true }
            let w = words(u.text)
            guard !w.isEmpty else { return false }
            let near = sys.filter { $0.end >= u.start - 2 && $0.start <= u.end + 2 }.map(\.text).joined(separator: " ")
            if near.isEmpty { return true }
            let set = Set(words(near))
            let hit = w.filter { set.contains($0) }.count
            return Double(hit) / Double(w.count) < 0.6
        }
    }

    static func clock(_ t: Double) -> String { reloj(t) }

    struct Line { let start: Double; var who: String; var text: String; var end: Double }

    /// Una línea por frase, sin juntar: así se puede poner nombre a cada una antes de unirlas.
    static func rawLines(_ utts: [Utterance]) -> [Line] {
        utts.sorted(by: { $0.start < $1.start }).map {
            Line(start: $0.start, who: $0.track == "mic" ? Config.userName : Config.othersLabel, text: $0.text, end: $0.end)
        }
    }

    /// Junta frases seguidas de la misma persona en un párrafo.
    static func merge(_ raw: [Line]) -> [Line] {
        var out: [Line] = []
        for l in raw {
            if var last = out.last, last.who == l.who, l.start - last.end < 4,
               l.end - last.start < 60, last.text.count < 700 {
                last.text += " " + l.text
                last.end = max(last.end, l.end)
                out[out.count - 1] = last
            } else {
                out.append(l)
            }
        }
        return out
    }

    static func lines(_ utts: [Utterance]) -> [Line] { merge(rawLines(utts)) }

    /// Cierra todo y deja el documento y el audio en la carpeta de salida. Devuelve el .docx.
    func finalize(audioSources: [URL], outputDir: URL? = nil, progress: ((String) -> Void)? = nil) async throws -> URL {
        progress?("Terminando de transcribir…")
        await transcriber.drain()
        if await !transcriber.failed.isEmpty { await transcriber.retryFailed() }
        let failedCount = await transcriber.failed.count
        let utts = MeetingSession.dedupe(await transcriber.results)
        var ls = MeetingSession.rawLines(utts)
        let canUseAI = Config.apiKey != nil   // resumen, nombres y cliente necesitan la clave de OpenAI
        if canUseAI, ls.contains(where: { $0.who == Config.othersLabel }) {
            progress?("Identificando a los participantes…")
            let numbered = ls.enumerated().map { "L\($0.offset) [\(MeetingSession.clock($0.element.start))] \($0.element.who): \($0.element.text)" }.joined(separator: "\n")
            do {
                let names = try await OpenAI.identifySpeakers(numbered: numbered)
                for (i, name) in names where i < ls.count && ls[i].who == Config.othersLabel { ls[i].who = name }
                log("Participantes identificados: \(Set(names.values).sorted().joined(separator: ", ")) en \(names.count) de \(ls.filter { $0.who != Config.userName }.count) líneas")
            } catch { log("No pude identificar participantes: \(error.localizedDescription)") }
        }
        ls = MeetingSession.merge(ls)
        let duration = max(Double(max(mic.position, sys.position)) / kSR, ls.last?.end ?? 0)
        let durText = MeetingSession.durationText(duration)
        let transcript = ls.map { "[\(MeetingSession.clock($0.start))] \($0.who): \($0.text)" }.joined(separator: "\n")

        var resumen: Resumen?
        if canUseAI, !transcript.isEmpty {
            progress?("Haciendo el resumen…")
            do { resumen = try await OpenAI.summarize(transcript: transcript, durationText: durText) } catch {
                log("Falló el resumen: \(error.localizedDescription)")
            }
        }

        // Reuniones / 2026-11 Noviembre / 2026-11-09 15.37 Título / (documento + audio)
        let root = outputDir ?? Config.outputFolder().url
        let es = Locale(identifier: "es_CL")
        let mf = DateFormatter()
        mf.locale = es
        mf.dateFormat = "MMMM"
        let monthName = mf.string(from: startDate)
        mf.dateFormat = "yyyy-MM"
        let monthDir = root.appendingPathComponent("\(mf.string(from: startDate)) \(monthName.prefix(1).uppercased() + monthName.dropFirst())", isDirectory: true)
        let df = DateFormatter()
        df.locale = es
        df.dateFormat = "yyyy-MM-dd HH.mm"
        func safe(_ s: String) -> String {
            s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var title = safe(resumen?.titulo ?? "Reunión")
        if let c = resumen?.cliente.map(safe), !c.isEmpty { title = "\(c) - \(title)" }
        var base = "\(df.string(from: startDate)) \(title)"
        var n = 2
        while FileManager.default.fileExists(atPath: monthDir.appendingPathComponent(base).path) {
            base = "\(df.string(from: startDate)) \(title) (\(n))"; n += 1
        }
        let out = monthDir.appendingPathComponent(base, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let docURL = out.appendingPathComponent(base + ".docx")
        let audioURL = out.appendingPathComponent(base + ".m4a")

        progress?("Guardando el audio…")
        let sources = audioSources.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !sources.isEmpty {
            do { try mixToM4A(sources, to: audioURL) } catch { log("No pude mezclar el audio: \(error)") }
        }

        progress?("Escribiendo el documento…")
        let html = DocBuilder.html(title: resumen?.titulo ?? "Reunión", date: startDate, duration: durText,
                                   resumen: resumen, lines: ls, failedCount: failedCount,
                                   audioName: FileManager.default.fileExists(atPath: audioURL.path) ? audioURL.lastPathComponent : nil)
        let htmlURL = dir.appendingPathComponent("documento.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", "docx", "-inputencoding", "UTF-8", "-output", docURL.path, htmlURL.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw EscribaError.other("No pude crear el documento") }

        if failedCount == 0 {
            try? FileManager.default.removeItem(at: dir)
        } else {
            try? "\(failedCount) fragmentos sin transcribir".write(to: dir.appendingPathComponent("PENDIENTE.txt"), atomically: true, encoding: .utf8)
        }
        return docURL
    }

    static func durationText(_ d: Double) -> String {
        let m = Int(d / 60), s = Int(d) % 60
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return m > 0 ? "\(m) min" : "\(s) s"
    }

    // MARK: Procesar archivos ya grabados (prueba y recuperación)

    func feedFiles(mic micURL: URL?, sys sysURL: URL?) {
        let mr = micURL.flatMap { try? MonoReader(url: $0) }
        let sr = sysURL.flatMap { try? MonoReader(url: $0) }
        var mDone = mr == nil, sDone = sr == nil
        while !(mDone && sDone) {
            if !mDone, let mr { let x = mr.read(Int(kSR)); if x.isEmpty { mDone = true } else { mic.append(x) } }
            if !sDone, let sr { let x = sr.read(Int(kSR)); if x.isEmpty { sDone = true } else { sys.append(x) } }
        }
        mic.flush()
        sys.flush()
    }
}

/// Lee un micrófono concreto en vez del micrófono del sistema. Se usa mientras Intérprete traduce tu voz:
/// ahí el micrófono del sistema es el virtual (sale tu voz traducida) y la grabación necesita tu voz real.
final class RealMic: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "escriba.mic-real")
    private(set) var name = ""
    var onBuffer: ((AVAudioPCMBuffer, Double) -> Void)?

    func start(preferido: String?) throws {
        // El que tenía el sistema antes de que Intérprete lo cambiara; si no se sabe, el mejor que no sea virtual.
        let before = preferido ?? Config.sibling("Interprete")["mic_anterior"] as? String
        let real = AudioDevices.inputs.first { $0.uid == before && !AudioDevices.isVirtual($0.name) } ?? AudioDevices.pickRealMic().real
        guard let real, !AudioDevices.isVirtual(real.name), let dev = AVCaptureDevice(uniqueID: real.uid) else {
            throw EscribaError.other("No encontré tu micrófono real")
        }
        let s = AVCaptureSession()
        s.addInput(try AVCaptureDeviceInput(device: dev))
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        s.addOutput(out)
        s.startRunning()
        session = s
        name = real.name
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pcm = sb.firstChannelBuffer() else { return }
        onBuffer?(pcm, sb.presentationTimeStamp.seconds)
    }

    func stop() {
        session?.stopRunning()
        session = nil
    }
}

/// Captura en vivo: micrófono con cancelación de eco + audio del sistema (lo que dicen los demás).
final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let session: MeetingSession
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private var hostStart: Double = 0
    private var activity: NSObjectProtocol?
    private let screenQueue = DispatchQueue(label: "escriba.screen")
    var onError: ((String) -> Void)?
    /// El micrófono del sistema es el virtual de Intérprete: tu voz se lee directo de tu micrófono real.
    private var externalMic = false
    private var realMic: RealMic?
    private var micListener: AudioObjectPropertyListenerBlock?
    private var launchObserver: NSObjectProtocol?
    private var running = false
    static let interpreterBundleID = "com.gopoint.interprete"

    init(session: MeetingSession) { self.session = session }

    /// El último micrófono real que tuvo el sistema: es el que hay que seguir grabando si Intérprete lo cambia.
    private static var lastRealMicUID: String?

    private static var systemMicIsVirtual: Bool {
        guard let d = AudioDevices.defaultInput else { return false }
        if AudioDevices.isVirtual(d.name) { return true }
        lastRealMicUID = d.uid
        return false
    }

    private func startRealMic() throws {
        let m = RealMic()
        m.onBuffer = { [weak self] buf, t in self?.feedMic(buf, hostTime: t) }
        try m.start(preferido: LiveCapture.lastRealMicUID)
        realMic = m
        log("Grabación: Intérprete está traduciendo tu voz, grabo directo de «\(m.name)»")
    }

    /// Cambia entre el micrófono del sistema y tu micrófono real, según si Intérprete tomó el del sistema.
    private func useExternalMic(_ on: Bool) {
        guard running, on != externalMic else { return }
        externalMic = on
        do {
            if on {
                stopMic()
                try startRealMic()
            } else {
                realMic?.stop()
                realMic = nil
                try startMic()
            }
        } catch {
            log("No pude cambiar de micrófono en la grabación: \(error)")
            onError?("No pude seguir grabando tu micrófono. La voz de los demás se sigue grabando.")
        }
    }

    private func feedMic(_ buf: AVAudioPCMBuffer, hostTime: Double) {
        guard externalMic, hostStart > 0 else { return }
        let s = session
        let t = hostTime - hostStart
        let wall = LiveCapture.hostNow() - hostStart
        s.queue.async { s.mic.ingest(buf, at: t, wallNow: wall) }
    }

    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start() async throws {
        hostStart = LiveCapture.hostNow()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Grabando una reunión")
        externalMic = LiveCapture.systemMicIsVirtual
        if externalMic { try startRealMic() } else { try startMic() }
        do {
            try await startSystemAudio()
        } catch {
            stopMic()
            realMic?.stop()
            throw EscribaError.other("No pude capturar el audio de la reunión. Revisa el permiso de Grabación de pantalla y audio del sistema. (\(error.localizedDescription))")
        }
        running = true
        watch()
    }

    private func startMic() throws {
        let input = engine.inputNode
        var vp = false
        do {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            vp = true
        } catch { log("Sin cancelación de eco: \(error)") }
        installTap()
        do {
            try engine.start()
        } catch where vp {
            log("El micrófono no partió con cancelación de eco, reintento sin ella: \(error)")
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            installTap()
            try engine.start()
        }
        log("Micrófono activo (cancelación de eco: \(input.isVoiceProcessingEnabled))")
    }

    private func installTap() {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        let s = session
        let start = hostStart
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, when in
            let t = (when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : LiveCapture.hostNow()) - start
            let wall = LiveCapture.hostNow() - start
            guard let c = deepCopy(buf) else { return }
            s.queue.async { s.mic.ingest(c, at: t, wallNow: wall) }
        }
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startSystemAudio() async throws {
        let filter = try await systemFilter()
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        let st = SCStream(filter: filter, configuration: cfg, delegate: self)
        try st.addStreamOutput(self, type: .audio, sampleHandlerQueue: session.queue)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await st.startCapture()
        stream = st
        log("Audio del sistema activo")
    }

    /// Todo lo que suena en el Mac, menos Intérprete: su voz traducida no es parte de la reunión
    /// y, si se grabara, quedaría encima de la voz original de los demás.
    private func systemFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw EscribaError.other("No encontré pantalla") }
        var out = content.applications.filter { $0.bundleIdentifier == LiveCapture.interpreterBundleID }
        if ProcessInfo.processInfo.environment["ESCRIBA_SIN_EXCLUIR"] != nil { out = [] }   // solo para pruebas
        if !out.isEmpty { log("Grabación: dejo fuera el audio de Intérprete") }
        return SCContentFilter(display: display, excludingApplications: out, exceptingWindows: [])
    }

    /// Avisos que la grabación necesita mientras dura: si Intérprete se abre, y si cambia el micrófono del sistema.
    private func watch() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, app?.bundleIdentifier == LiveCapture.interpreterBundleID else { return }
            Task {
                // Intérprete tarda un instante en aparecer en la lista de apps que se pueden excluir.
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let st = self.stream else { return }
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                        guard content.applications.contains(where: { $0.bundleIdentifier == LiveCapture.interpreterBundleID }) else { continue }
                        try await st.updateContentFilter(try await self.systemFilter())
                        return
                    } catch { log("Grabación: no pude dejar fuera a Intérprete: \(error.localizedDescription)") }
                }
                log("Grabación: Intérprete se abrió pero no aparece para excluirlo")
            }
        }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.useExternalMic(LiveCapture.systemMicIsVirtual) }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, l)
        micListener = l
    }

    private func unwatch() {
        if let o = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        launchObserver = nil
        if let l = micListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, l)
        }
        micListener = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let pcm = sb.toPCMBuffer() else { return }
        let t = sb.presentationTimeStamp.seconds - hostStart
        session.sys.ingest(pcm, at: t, wallNow: LiveCapture.hostNow() - hostStart)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("La captura del sistema se detuvo: \(error)")
        onError?("Se cortó la captura del audio de la reunión: \(error.localizedDescription)")
    }

    func stop() async {
        running = false
        unwatch()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        stopMic()
        realMic?.stop()
        realMic = nil
        let s = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.queue.async { s.mic.flush(); s.sys.flush(); c.resume() }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
