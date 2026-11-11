import AVFoundation
import CoreAudio

/// Toma el audio de todas las demás apps y, si se pide, las silencia en los parlantes.
/// Así Escriba puede volver a reproducirlas más bajo mientras suena la traducción. Necesita macOS 14.2.
@available(macOS 14.2, *)
final class SystemTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?
    private let queue: DispatchQueue
    /// Audio de las demás apps, tal como llega (se entrega en la cola indicada).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    private static func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw EscribaError.other("\(what) (código \(st))") }
    }

    static func defaultOutputUID() throws -> String {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev), "No encontré la salida de audio")
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        a.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &uid), "No pude leer la salida de audio")
        guard let s = uid?.takeRetainedValue() else { throw EscribaError.other("No pude leer la salida de audio") }
        return s as String
    }

    /// Con `only` se captura solo lo que suena desde ese proceso (para pruebas); sin él, todo menos Escriba.
    func start(mute: Bool, only: pid_t? = nil) throws {
        // Escriba se excluye: su propia voz traducida no debe volver a entrar ni silenciarse.
        var pid = only ?? getpid()
        var me = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        guard st == noErr, me != kAudioObjectUnknown else { throw EscribaError.other("El sistema no reconoce a Escriba como app de audio") }

        let desc = only == nil ? CATapDescription(stereoGlobalTapButExcludeProcesses: [me]) : CATapDescription(stereoMixdownOfProcesses: [me])
        desc.uuid = UUID()
        desc.name = "Escriba"
        desc.isPrivate = true
        desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        try SystemTap.check(AudioHardwareCreateProcessTap(desc, &tapID), "No pude tomar el audio del sistema")

        do {
            var asbd = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try SystemTap.check(AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &asbd), "No pude leer el formato del audio")
            guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw EscribaError.other("Formato de audio desconocido") }
            format = fmt

            let out = try SystemTap.defaultOutputUID()
            let agg: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Escriba traductor",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: out,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: out]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            try SystemTap.check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "No pude preparar la captura")

            let buffers = fmt.isInterleaved ? 1 : Int(fmt.channelCount)
            let bytesPerFrame = Int(fmt.streamDescription.pointee.mBytesPerFrame)
            try SystemTap.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, inData, _, _, _ in
                guard let self, let cb = self.onBuffer else { return }
                let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                guard src.count >= buffers, bytesPerFrame > 0 else { return }
                let first = src.count - buffers   // si la salida también trae micrófono, la captura viene al final
                let frames = Int(src[first].mDataByteSize) / bytesPerFrame
                guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
                b.frameLength = AVAudioFrameCount(frames)
                let dst = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
                for i in 0..<min(buffers, dst.count) {
                    if let s = src[first + i].mData, let d = dst[i].mData {
                        memcpy(d, s, Int(min(src[first + i].mDataByteSize, dst[i].mDataByteSize)))
                    }
                }
                cb(b)
            }, "No pude leer el audio del sistema")
            try SystemTap.check(AudioDeviceStart(aggID, procID), "No pude iniciar la captura")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

/// Cola de audio entre quien produce y el dispositivo que reproduce.
final class AudioRing {
    private var buf: [Float] = []
    private var head = 0
    private var primed = false
    private let lock = NSLock()
    private let cushion: Int
    private let limit: Int
    private let rate: Double
    private var gain: Float = 1
    private var idleGain: Float = 1
    private var duckedGain: Float = 1
    private let down: Float     // baja en unos 40 ms
    private let up: Float       // vuelve en unos 300 ms

    init(sampleRate: Double, cushion: Double = 0.08, limit: Double = 0.5) {
        rate = sampleRate
        down = 1 - exp(-1 / Float(0.04 * sampleRate))
        up = 1 - exp(-1 / Float(0.30 * sampleRate))
        self.cushion = Int(sampleRate * cushion)
        self.limit = Int(sampleRate * limit)
        buf.reserveCapacity(self.limit + 65536)
    }

    /// Segundos de audio en espera.
    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buf.count - head) / rate
    }

    func write(_ s: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if head > 65536 { buf.removeFirst(head); head = 0 }
        buf += s
        if buf.count - head > limit { head = buf.count - cushion }
    }

    /// Volumen del original: `idle` cuando la traducción calla y `ducked` mientras habla.
    func setLevels(idle: Float, ducked: Float, immediately: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        idleGain = idle
        duckedGain = ducked
        if immediately { gain = idle }
    }

    /// Lee aplicando el volumen del original, con transiciones suaves.
    func read(_ out: UnsafeMutablePointer<Float>, _ n: Int, ducked: Bool) {
        lock.lock(); defer { lock.unlock() }
        let have = buf.count - head
        if !primed { primed = have >= cushion }
        let k = primed ? min(n, have) : 0
        let target = ducked ? duckedGain : idleGain
        let coef = target < gain ? down : up
        for i in 0..<k {
            gain += (target - gain) * coef
            out[i] = buf[head + i] * gain
        }
        if k < n {
            for i in k..<n { out[i] = 0 }
            primed = false
            gain += (target - gain) * min(1, coef * Float(n - k))
        }
        head += k
    }

    func read(_ out: UnsafeMutablePointer<Float>, _ n: Int, gain: Float) {
        lock.lock(); defer { lock.unlock() }
        let have = buf.count - head
        if !primed { primed = have >= cushion }
        let k = primed ? min(n, have) : 0
        for i in 0..<k { out[i] = buf[head + i] * gain }
        if k < n { for i in k..<n { out[i] = 0 }; primed = false }
        head += k
    }
}
