import AVFoundation
import CoreAudio
import AudioToolbox

/// Escribe audio directo en un dispositivo (el micrófono virtual), sin depender de la salida del sistema.
final class DeviceOutput {
    private let device: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private var ring: AudioRing
    private var rate: Double
    private var conv: Mono24Converter
    private let lock = NSLock()
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 32768)
    private var listener: AudioObjectPropertyListenerBlock?
    /// De dónde sale el audio (24 kHz). Se le pide justo lo que falta, al ritmo del propio dispositivo.
    var source: ((UnsafeMutablePointer<Float>, Int) -> Void)?
    private let wake = DispatchSemaphore(value: 0)
    private var running = false
    /// Audio que se mantiene listo por delante: unos tres ciclos del dispositivo.
    private static let ahead = 0.03

    private static func nominalRate(_ id: AudioDeviceID) -> Double {
        var r: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &r)
        return r > 0 ? r : 48000
    }

    private static func make(_ rate: Double) -> (AudioRing, Mono24Converter) {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        return (AudioRing(sampleRate: rate, cushion: 0.01, limit: 2), Mono24Converter(to: f))
    }

    init(device: AudioDeviceID) {
        self.device = device
        rate = DeviceOutput.nominalRate(device)
        (ring, conv) = DeviceOutput.make(rate)
    }

    deinit { scratch.deallocate() }

    var backlog: Double { lock.lock(); defer { lock.unlock() }; return ring.seconds }

    func start() throws {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &asbd) == noErr,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            throw EscribaError.other("El micrófono virtual tiene un formato que no conozco")
        }
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, _, _, outData, _ in
            let bufs = UnsafeMutableAudioBufferListPointer(outData)
            guard let self else { for b in bufs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }; return }
            for b in bufs {
                let ch = max(1, Int(b.mNumberChannels))
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = min(Int(b.mDataByteSize) / (4 * ch), 32768)
                self.lock.lock(); let r = self.ring; self.lock.unlock()
                r.read(self.scratch, frames, gain: 1)
                for i in 0..<frames { for c in 0..<ch { d[i * ch + c] = self.scratch[i] } }
            }
            self.wake.signal()   // el dispositivo acaba de consumir: toca reponer
        }
        guard st == noErr, let procID, AudioDeviceStart(device, procID) == noErr else {
            throw EscribaError.other("No pude escribir en el micrófono virtual (código \(st))")
        }
        // Si otra app le cambia la frecuencia al dispositivo, se sigue con la nueva.
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let r = DeviceOutput.nominalRate(self.device)
            self.lock.lock()
            if r != self.rate { self.rate = r; (self.ring, self.conv) = DeviceOutput.make(r) }
            self.lock.unlock()
            log("Micrófono virtual: frecuencia \(Int(r)) Hz")
        }
        AudioObjectAddPropertyListenerBlock(device, &ra, DispatchQueue.global(), l)
        listener = l
        // Un hilo propio repone el audio cada vez que el dispositivo consume. Así no depende de ningún reloj
        // de la app (macOS los frena cuando la app está en segundo plano).
        running = true
        let t = Thread { [weak self] in
            while true {
                guard let s = self, s.running else { return }
                _ = s.wake.wait(timeout: .now() + 0.05)
                s.refill()
            }
        }
        t.qualityOfService = .userInteractive
        t.name = "escriba.microfono-virtual"
        t.start()
    }

    private func refill() {
        guard let source else { return }
        lock.lock(); let have = ring.seconds; lock.unlock()
        let need = Int((DeviceOutput.ahead - have) * kTR)
        guard need > 0 else { return }
        var buf = [Float](repeating: 0, count: need)
        buf.withUnsafeMutableBufferPointer { source($0.baseAddress!, need) }
        write(buf)
    }

    /// Audio mono a 24 kHz.
    func write(_ samples: [Float]) {
        guard let b = AVAudioPCMBuffer(pcmFormat: mono24k, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        lock.lock(); defer { lock.unlock() }
        ring.write(conv.convert(b))
    }

    func stop() {
        running = false
        wake.signal()
        if let l = listener {
            var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &ra, DispatchQueue.global(), l)
        }
        listener = nil
        if let procID { AudioDeviceStop(device, procID); AudioDeviceDestroyIOProcID(device, procID) }
        procID = nil
    }
}

/// Toma tu micrófono, lo traduce y manda la voz traducida al micrófono virtual que usa la reunión.
final class VoiceTranslator: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let idleLimit: TimeInterval = 600
    private var capture: AVCaptureSession?
    private var realMic: (id: AudioDeviceID, name: String, uid: String)?
    private var warned = false
    private var callbacks = 0
    private(set) var micName = ""
    /// El audio de tu micrófono real, para que la grabación de la reunión lo siga recibiendo.
    var onMicBuffer: ((AVAudioPCMBuffer, Double) -> Void)?
    var onWarning: ((String) -> Void)?

    private let socket = TranslateSocket()
    private var output: DeviceOutput?
    private var previousDefault: AudioDeviceID?
    private var bridge: AudioDeviceID?
    private var users = ""
    private var lastUsersCheck = Date.distantPast
    private let queue = DispatchQueue(label: "escriba.mivoz")
    private let conv = Mono24Converter()
    private lazy var feeder = Feeder(socket: socket)
    private let playout = Playout(speedUp: Config.catchUp)
    private let meter = LatencyMeter()
    private var activity: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var chars = 0
    private var testText = ""
    private(set) var startDate = Date()
    private(set) var deviceName = ""
    var onAutoStop: ((String) -> Void)?

    func start(language: String) async throws {
        guard let mic = AudioDevices.virtualMic else {
            throw EscribaError.other("Falta instalar el micrófono virtual (BlackHole).")
        }
        let (real, system) = AudioDevices.pickRealMic()
        if let s = system, !AudioDevices.isVirtual(s.name) { previousDefault = s.id }
        guard let real, let camDevice = AVCaptureDevice(uniqueID: real.uid) else {
            throw EscribaError.other("No encontré tu micrófono. Revisa Ajustes del Sistema > Sonido > Entrada.")
        }
        realMic = real
        micName = real.name
        deviceName = mic.name
        let p = playout
        socket.onAudio = { p.push($0) }
        socket.onText = { [weak self] t in self?.queue.async { self?.chars += t.count; self?.testText += t } }
        socket.onDropped = { [weak self] m in self?.autoStop(m) }
        try await socket.connect(language: language)
        do {
            // Salida: directo al micrófono virtual, nunca a los audífonos.
            let o = DeviceOutput(device: mic.id)
            o.source = { p.pull($0, $1) }
            try o.start()
            output = o
            bridge = Config.useBridge ? AudioDevices.createBridge(over: mic.id) : nil
            if bridge != nil { deviceName = AudioDevices.bridgeName }
            if let f = ProcessInfo.processInfo.environment["ESCRIBA_VOZ_ARCHIVO"] {
                try feedFile(URL(fileURLWithPath: f))   // prueba: un archivo en vez del micrófono
            } else {
                let s = AVCaptureSession()
                s.addInput(try AVCaptureDeviceInput(device: camDevice))
                let out = AVCaptureAudioDataOutput()
                out.setSampleBufferDelegate(self, queue: queue)
                s.addOutput(out)
                s.startRunning()
                capture = s
                // El sistema pasa a usar el micrófono virtual: así sirve en apps que no dejan elegirlo (WhatsApp).
                try? Config.update(["mic_anterior": system.flatMap { AudioDevices.isVirtual($0.name) ? nil : $0.uid } ?? real.uid])
                AudioDevices.realMicUID = real.uid
                if !AudioDevices.setDefaultInput(bridge ?? mic.id) { log("No pude cambiar el micrófono del sistema a \(deviceName)") }
            }
        } catch {
            capture?.stopRunning(); output?.stop(); AudioDevices.removeBridge()
            await socket.close()
            throw error
        }
        startDate = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated, .latencyCritical], reason: "Traduciendo tu voz")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
        log("Traducción de mi voz activa (\(language)): \(real.name) → \(mic.name)\(bridge != nil ? " (presentado como \(AudioDevices.bridgeName))" : "")")
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        callbacks += 1
        guard let pcm = sb.firstChannelBuffer() else { return }
        onMicBuffer?(pcm, sb.presentationTimeStamp.seconds)
        ingest(conv.convert(pcm))
    }

    private func feedFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
        try file.read(into: buf)
        let all = Mono24Converter().convert(buf)
        let n = TranslateSocket.chunk
        var i = 0
        let src = DispatchSource.makeTimerSource(queue: queue)
        src.schedule(deadline: .now() + 0.5, repeating: 0.2)
        src.setEventHandler { [weak self] in
            guard i + n <= all.count else { src.cancel(); return }
            self?.ingest(Array(all[i..<(i + n)]))
            i += n
        }
        src.resume()
    }

    private func ingest(_ s: [Float]) {
        feeder.ingest(s)
    }

    private func pump() {
        if Date().timeIntervalSince(lastUsersCheck) > 3 {
            lastUsersCheck = Date()
            let u = AudioDevices.inputUsers().filter { !$0.hasPrefix("com.gopoint.escriba") }.joined(separator: " | ")
            if u != users { users = u; log("Apps con micrófono abierto: \(u.isEmpty ? "ninguna" : u)") }
        }
        if !warned, capture != nil, Date().timeIntervalSince(startDate) > 12, feeder.peak < 0.004 {
            warned = true
            let n = micName
            DispatchQueue.main.async { self.onWarning?("El micrófono «\(n)» no está captando sonido. Elige otro en Ajustes del Sistema > Sonido > Entrada y vuelve a activar la traducción.") }
        }
        feeder.tick()
        meter.tick(lastSpeech: feeder.lastSpeech, sinceLoudOut: playout.sinceLoudOut)
        if Date().timeIntervalSince(max(feeder.lastSpeech, startDate)) > VoiceTranslator.idleLimit {
            autoStop("Pasaron 10 minutos sin que hablaras, así que detuve la traducción de tu voz.")
        }
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
        capture?.stopRunning()
        capture = nil
        if let r = realMic, AudioDevices.realMicUID != nil {
            AudioDevices.setDefaultInput(previousDefault ?? r.id)   // el sistema vuelve al micrófono que tenía
            AudioDevices.realMicUID = nil
            try? Config.update(["mic_anterior": nil])
        }
        let st = playout.snapshot   // antes de cerrar: al cerrar, OpenAI vacía de golpe varios segundos de silencio
        await socket.close()
        try? await Task.sleep(nanoseconds: 300_000_000)
        output?.stop()
        output = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        AudioDevices.removeBridge()
        bridge = nil
        let (c, t, speech, pk, delay) = queue.sync { (chars, testText, feeder.speechSeconds, feeder.peak, meter.summary) }
        log("Traducción de mi voz detenida a los \(reloj(Date().timeIntervalSince(startDate))): \(Int(speech)) s hablando, \(Int(Double(st.loudOut) / kTR)) s de voz traducida, \(c) letras, pico del micrófono \(String(format: "%.3f", pk)) en \(callbacks) entregas")
        log("Traducción de mi voz, retraso: \(delay ?? "sin frases que medir"). \(Playout.describe(st))")
        if ProcessInfo.processInfo.environment["ESCRIBA_PRUEBA"] != nil { log("Texto de prueba: \(t)") }
    }
}

/// Prueba: graba unos segundos desde una entrada por nombre (por ejemplo el micrófono virtual).
final class ListenTest: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let conv = MonoConverter(firstChannelOnly: false)
    private let lock = NSLock()
    private var all: [Float] = []

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pcm = sb.toPCMBuffer() else { return }
        let s = conv.convert(pcm)
        lock.lock(); all += s; lock.unlock()
    }

    static func run(device part: String, seconds: Double, output: URL) throws {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
        guard let d = found.first(where: { $0.localizedName.localizedCaseInsensitiveContains(part) }) else {
            throw EscribaError.other("No encontré la entrada \(part). Hay: \(found.map(\.localizedName))")
        }
        let t = ListenTest()
        let session = AVCaptureSession()
        session.addInput(try AVCaptureDeviceInput(device: d))
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(t, queue: DispatchQueue(label: "escriba.escuchar"))
        session.addOutput(out)
        session.startRunning()
        Thread.sleep(forTimeInterval: seconds)
        session.stopRunning()
        t.lock.lock(); defer { t.lock.unlock() }
        let loud = t.all.filter { abs($0) > 0.02 }.count
        print("\(d.localizedName): \(String(format: "%.1f", Double(t.all.count) / kSR)) s grabados, \(String(format: "%.1f", Double(loud) / kSR)) s con sonido")
        try writeWAV(t.all, to: output)
    }
}
