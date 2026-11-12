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
        // El micrófono del iPhone va al final: usarlo enciende el teléfono, y casi nunca es el que se quiere.
        let others = inputs.filter { !isVirtual($0.name) && !(closed && $0.name.contains("MacBook")) }
            .sorted { !$0.name.contains("iPhone") && $1.name.contains("iPhone") }
        var real = system
        let pref = Config.preferredMic
        if !pref.isEmpty, let p = others.first(where: { $0.name.localizedCaseInsensitiveContains(pref) }) { real = p }
        else if let r = real, isVirtual(r.name) || (closed && r.name.contains("MacBook")) { real = others.first(where: { $0.name.contains("MacBook") }) ?? others.first }
        return (real, system)
    }

    static func isVirtual(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains(Config.virtualMicName) || name == bridgeName || name == "Micrófono Escriba"
    }

    /// Algunas apps (WhatsApp) esconden los micrófonos virtuales. Este dispositivo agrupado envuelve al virtual
    /// y se presenta como un micrófono más.
    static let bridgeName = "Micrófono Intérprete"
    static let bridgeUID = "com.gopoint.interprete.microfono"

    static func removeBridge() {
        for d in inputs where d.uid == bridgeUID || d.uid == "com.gopoint.escriba.microfono" { AudioHardwareDestroyAggregateDevice(d.id) }
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
