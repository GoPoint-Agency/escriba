import Foundation
import CryptoKit

/// Elige con qué se transcribe: OpenAI o Whisper en el propio Mac.
enum Engine {
    static func transcribe(file: URL, prompt: String?) async throws -> String {
        if Config.isLocal { return try await LocalWhisper.shared.transcribe(file: file, prompt: prompt) }
        return try await OpenAI.transcribe(file: file, prompt: prompt)
    }

    /// Lo que falta para poder transcribir, o nil si está todo listo.
    static var missing: String? {
        if Config.isLocal { return LocalWhisper.modelReady ? nil : "Falta descargar el modelo de Whisper" }
        return Config.apiKey == nil ? "Falta la clave de OpenAI" : nil
    }

    static var vocabularyPrompt: String? {
        let v = Config.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : "Vocabulario: \(v)."
    }
}

/// Whisper (whisper.cpp, modelo large-v3-turbo) corriendo dentro de la app, sin internet.
final class LocalWhisper {
    static let shared = LocalWhisper()
    static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    static let modelSHA256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    static let modelBytes: Int64 = 574_041_195
    static let modelSource = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    static var modelURL: URL {
        let d = Config.appSupport.appendingPathComponent("modelos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(modelName)
    }

    static var modelReady: Bool {
        let a = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
        return (a?[.size] as? NSNumber)?.int64Value == modelBytes
    }

    private let queue = DispatchQueue(label: "escriba.whisper")   // whisper no admite dos trabajos a la vez
    private var ctx: OpaquePointer?

    private(set) static var started = false

    /// Libera el modelo antes de salir (si no, la GPU se queja al cerrar la app).
    static func shutdown() {
        guard started else { return }
        shared.queue.sync {
            if let c = shared.ctx { whisper_free(c); shared.ctx = nil }
        }
    }

    private init() {
        LocalWhisper.started = true
        whisper_log_set({ _, _, _ in }, nil)   // sin ruido en la consola
    }

    func transcribe(file: URL, prompt: String?) async throws -> String {
        // Leer el audio fuera de la cola de whisper.
        let samples: [Float] = try {
            let r = try MonoReader(url: file)
            var all: [Float] = []
            while true { let x = r.read(Int(kSR) * 10); if x.isEmpty { break }; all += x }
            return all
        }()
        guard samples.count > Int(kSR / 4) else { return "" }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.run(samples, prompt: prompt)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func run(_ samples: [Float], prompt: String?) throws -> String {
        if ctx == nil {
            guard LocalWhisper.modelReady else { throw EscribaError.other("Falta descargar el modelo de Whisper") }
            let t0 = Date()
            var cp = whisper_context_default_params()
            #if arch(arm64)
            cp.use_gpu = true
            #else
            cp.use_gpu = false
            #endif
            ctx = whisper_init_from_file_with_params(LocalWhisper.modelURL.path, cp)
            guard ctx != nil else { throw EscribaError.other("No pude abrir el modelo de Whisper") }
            log("Whisper cargado en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        }
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.print_special = false
        p.no_timestamps = true
        p.suppress_blank = true
        // El modelo siempre mira ventanas de 30 s; con frases cortas se le achica la ventana (2 a 3 veces más rápido).
        let dur = Double(samples.count) / kSR
        if dur < 28 {
            let frames = Int(dur * 50) + 128
            p.audio_ctx = Int32(min(1500, ((frames + 63) / 64) * 64))
        }
        let t0 = Date()
        let rc: Int32 = "es".withCString { lang in
            p.language = lang
            if let prompt, !prompt.isEmpty {
                return prompt.withCString { pr in
                    p.initial_prompt = pr
                    return samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
                }
            }
            return samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
        guard rc == 0 else { throw EscribaError.other("Whisper no pudo transcribir (código \(rc))") }
        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let c = whisper_full_get_segment_text(ctx, i) { text += String(cString: c) }
        }
        log("Whisper: \(String(format: "%.1f", dur)) s de audio en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Descarga el modelo una sola vez, con avance, y revisa que llegó entero.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onDone: ((Error?) -> Void)?
    private var session: URLSession!

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session.downloadTask(with: LocalWhisper.modelSource).resume()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        onProgress?(Double(w) / Double(e > 0 ? e : LocalWhisper.modelBytes))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
        let fm = FileManager.default
        let dest = LocalWhisper.modelURL
        let part = dest.appendingPathExtension("parcial")
        do {
            try? fm.removeItem(at: part)
            try fm.moveItem(at: tmp, to: part)
            guard try ModelDownloader.sha256(part) == LocalWhisper.modelSHA256 else {
                try? fm.removeItem(at: part)
                throw EscribaError.other("El modelo llegó dañado. Vuelve a intentarlo.")
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
            onDone?(nil)
        } catch { onDone?(error) }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onDone?(error); s.finishTasksAndInvalidate() }
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
