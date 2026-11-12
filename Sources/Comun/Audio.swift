import AVFoundation
import CoreMedia

let kSR: Double = 16000
let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: kSR, channels: 1, interleaved: false)!

func pcm16Settings() -> [String: Any] {
    [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: kSR, AVNumberOfChannelsKey: 1,
     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
}

func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
    b.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
    return b
}

func writeWAV(_ samples: [Float], to url: URL) throws {
    let f = try AVAudioFile(forWriting: url, settings: pcm16Settings(), commonFormat: .pcmFormatFloat32, interleaved: false)
    if let b = makeBuffer(samples) { try f.write(from: b) }
}

func deepCopy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: max(b.frameLength, 1)) else { return nil }
    c.frameLength = b.frameLength
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
    let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
    for i in 0..<min(src.count, dst.count) {
        if let s = src[i].mData, let d = dst[i].mData {
            memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
    }
    return c
}

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fd = formatDescription, let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

/// Convierte cualquier buffer a mono 16 kHz Float32, manteniendo estado entre llamadas.
final class MonoConverter {
    private var conv: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    let firstChannelOnly: Bool

    init(firstChannelOnly: Bool) { self.firstChannelOnly = firstChannelOnly }

    func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        var buf = input
        // Micrófono con procesamiento de voz: a veces trae varios canales y solo el primero sirve.
        if firstChannelOnly, buf.format.channelCount > 1, !buf.format.isInterleaved,
           buf.format.commonFormat == .pcmFormatFloat32, let ch = buf.floatChannelData,
           let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false),
           let m = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: buf.frameLength) {
            m.frameLength = buf.frameLength
            m.floatChannelData![0].update(from: ch[0], count: Int(buf.frameLength))
            buf = m
        }
        let fmt = buf.format
        if fmt.sampleRate == kSR, fmt.channelCount == 1, fmt.commonFormat == .pcmFormatFloat32, let ch = buf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        }
        if conv == nil || inFormat != fmt {
            conv = AVAudioConverter(from: fmt, to: mono16k)
            conv?.downmix = true
            inFormat = fmt
        }
        guard let conv else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * kSR / fmt.sampleRate + 2048)
        guard let out = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: cap) else { return [] }
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

/// Lee un archivo de audio cualquiera como mono 16 kHz, por partes.
final class MonoReader {
    let file: AVAudioFile
    private var conv: AVAudioConverter?
    private var ended = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        let f = file.processingFormat
        if !(f.sampleRate == kSR && f.channelCount == 1) {
            conv = AVAudioConverter(from: f, to: mono16k)
            conv?.downmix = true
        }
    }

    func read(_ n: Int) -> [Float] {
        if ended { return [] }
        guard let out = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: AVAudioFrameCount(n)) else { return [] }
        if let conv {
            var err: NSError?
            let st = conv.convert(to: out, error: &err) { req, status in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: self.file.processingFormat, frameCapacity: req) else {
                    status.pointee = .endOfStream; return nil
                }
                do { try self.file.read(into: inBuf, frameCount: req) } catch { status.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return inBuf
            }
            if st == .error || st == .endOfStream && out.frameLength == 0 { ended = true }
        } else {
            do { try file.read(into: out, frameCount: AVAudioFrameCount(n)) } catch { ended = true; return [] }
        }
        if out.frameLength == 0 { ended = true; return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// Mezcla varias pistas en un .m4a mono liviano (32 kbps).
func mixToM4A(_ sources: [URL], to url: URL) throws {
    let readers = sources.compactMap { try? MonoReader(url: $0) }
    guard !readers.isEmpty else { throw EscribaError.other("No hay audio para mezclar") }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: kSR,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
    let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = Int(kSR) * 5
    while true {
        let parts = readers.map { $0.read(chunk) }
        let n = parts.map(\.count).max() ?? 0
        if n == 0 { break }
        var mix = [Float](repeating: 0, count: n)
        for p in parts { for i in 0..<p.count { mix[i] += p[i] } }
        for i in 0..<n { mix[i] = max(-1, min(1, mix[i])) }
        if let b = makeBuffer(mix) { try out.write(from: b) }
    }
}
