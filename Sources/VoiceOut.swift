import AVFoundation
import CoreAudio
import AudioToolbox
import IOKit

/// Dispositivos de audio por nombre.
enum AudioDevices {
    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, p) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(p.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Primera salida cuyo nombre contiene el texto.
    static func output(named part: String) -> (id: AudioDeviceID, name: String)? { device(named: part, scope: kAudioObjectPropertyScopeOutput) }

    static func device(named part: String, scope: AudioObjectPropertyScope) -> (id: AudioDeviceID, name: String)? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            guard let n = string(id, kAudioObjectPropertyName), n.localizedCaseInsensitiveContains(part),
                  channels(id, scope) > 0 else { continue }
            return (id, n)
        }
        return nil
    }

    static var defaultInput: (id: AudioDeviceID, name: String, uid: String)? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr,
              let n = string(dev, kAudioObjectPropertyName), let u = string(dev, kAudioDevicePropertyDeviceUID) else { return nil }
        return (dev, n, u)
    }

    static var defaultInputName: String? { defaultInput?.name }

    /// Todas las entradas: (id, nombre, uid).
    static var inputs: [(id: AudioDeviceID, name: String, uid: String)] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channels(id, kAudioObjectPropertyScopeInput) > 0, let n = string(id, kAudioObjectPropertyName),
                  let u = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return (id, n, u)
        }
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var dev = id
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    /// Con la tapa cerrada, macOS apaga el micrófono del MacBook: entrega silencio absoluto.
    static var lidClosed: Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        let v = IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }

    /// El micrófono real por el que se te escucha al traducir tu voz, y el que tiene puesto el sistema.
    /// Va el preferido de los ajustes; si no hay, el del sistema; y si ese es el virtual, el del Mac.
    /// El del MacBook se descarta con la tapa cerrada, porque no capta nada.
    static func pickRealMic() -> (real: (id: AudioDeviceID, name: String, uid: String)?, system: (id: AudioDeviceID, name: String, uid: String)?) {
        let system = defaultInput
        let closed = lidClosed
        let others = inputs.filter { !isVirtual($0.name) && !(closed && $0.name.contains("MacBook")) }
        var real = system
        let pref = Config.preferredMic
        if !pref.isEmpty, let p = others.first(where: { $0.name.localizedCaseInsensitiveContains(pref) }) { real = p }
        else if let r = real, isVirtual(r.name) || (closed && r.name.contains("MacBook")) { real = others.first(where: { $0.name.contains("MacBook") }) ?? others.first }
        return (real, system)
    }

    static func isVirtual(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains(Config.virtualMicName) || name == bridgeName
    }

    /// Algunas apps (WhatsApp) esconden los micrófonos virtuales. Este dispositivo agrupado envuelve al virtual
    /// y se presenta como un micrófono más.
    static let bridgeName = "Micrófono Escriba"
    static let bridgeUID = "com.gopoint.escriba.microfono"

    static func removeBridge() {
        for d in inputs where d.uid == bridgeUID { AudioHardwareDestroyAggregateDevice(d.id) }
    }

    static func createBridge(over virtualID: AudioDeviceID) -> AudioDeviceID? {
        removeBridge()
        guard let sub = string(virtualID, kAudioDevicePropertyDeviceUID) else { return nil }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: bridgeName,
            kAudioAggregateDeviceUIDKey: bridgeUID,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: sub,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: sub]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Mientras se traduce tu voz, el micrófono del sistema es el virtual. Este es el real.
    static var realMicUID: String?

    /// Si Escriba se cerró mal con el micrófono virtual puesto, se devuelve el tuyo.
    static func restoreMicIfNeeded() {
        guard let uid = Config.settings["mic_anterior"] as? String else { return }
        if let d = inputs.first(where: { $0.uid == uid }), let cur = defaultInput, isVirtual(cur.name) {
            setDefaultInput(d.id)
            log("Micrófono del sistema devuelto a \(d.name)")
        }
        removeBridge()
        try? Config.update(["mic_anterior": nil])
    }

    /// El micrófono virtual por donde sale la voz traducida hacia la reunión.
    static var virtualMic: (id: AudioDeviceID, name: String)? {
        output(named: ProcessInfo.processInfo.environment["ESCRIBA_MIC_VIRTUAL"] ?? Config.virtualMicName)
    }
}

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

extension AudioDevices {
    /// Qué apps tienen un micrófono abierto y cuál (macOS 14.2 o más nuevo). Sirve para saber si la llamada usa el virtual.
    static func inputUsers() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &procs) == noErr else { return [] }
        let names = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.name) })
        var out: [String] = []
        for p in procs {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var ra = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(p, &ra, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            var bid: Unmanaged<CFString>?
            s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var ba = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(p, &ba, 0, nil, &s, &bid)
            let app = (bid?.takeRetainedValue() as String?) ?? "?"
            var da = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ds: UInt32 = 0
            var devs: [AudioObjectID] = []
            if AudioObjectGetPropertyDataSize(p, &da, 0, nil, &ds) == noErr, ds > 0 {
                devs = [AudioObjectID](repeating: 0, count: Int(ds) / MemoryLayout<AudioObjectID>.size)
                AudioObjectGetPropertyData(p, &da, 0, nil, &ds, &devs)
            }
            out.append("\(app) → \(devs.map { names[$0] ?? "dispositivo \($0)" }.joined(separator: ", "))")
        }
        return out.sorted()
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
        log("Traducción de mi voz detenida a los \(MeetingSession.clock(Date().timeIntervalSince(startDate))): \(Int(speech)) s hablando, \(Int(Double(st.loudOut) / kTR)) s de voz traducida, \(c) letras, pico del micrófono \(String(format: "%.3f", pk)) en \(callbacks) entregas")
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

extension CMSampleBuffer {
    /// Solo el primer canal, como mono Float32. Sirve aunque el micrófono entregue varios canales
    /// (pasa cuando otra parte de la app usa cancelación de eco).
    func firstChannelBuffer() -> AVAudioPCMBuffer? {
        guard let fd = formatDescription, let p = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = p.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, let block = dataBuffer else { return nil }
        let n = numSamples
        let chans = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bytes = Int(asbd.mBitsPerChannel) / 8
        guard n > 0, chans > 0, bytes == 2 || bytes == 4,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        let stride = interleaved ? chans * bytes : bytes
        let need = n * stride
        var data = Data(count: need)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard CMBlockBufferGetDataLength(block) >= need else { return false }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: need, destination: raw.baseAddress!) == kCMBlockBufferNoErr
        }
        guard ok else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        let dst = out.floatChannelData![0]
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = i * stride
                if isFloat && bytes == 4 { dst[i] = raw.loadUnaligned(fromByteOffset: o, as: Float.self) }
                else if bytes == 2 { dst[i] = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self)) / 32768 }
                else { dst[i] = Float(raw.loadUnaligned(fromByteOffset: o, as: Int32.self)) / 2147483648 }
            }
        }
        return out
    }
}
