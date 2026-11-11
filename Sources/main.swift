import AppKit
import AVFoundation
import Foundation

/// Modos de línea de comandos para configurar y probar sin abrir la app.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let cmd = args[1]
        switch cmd {
        case "--set-key":
            let key = (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { print("Falta la clave por la entrada estándar"); return 1 }
            let url = Config.appSupport.appendingPathComponent("config.json")
            var j = Config.settings
            j["openai_api_key"] = key
            do {
                try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                print("Clave guardada (solo tu usuario puede leerla)")
            } catch { print("No pude guardar la clave: \(error)"); return 1 }
            return 0
        case "--check":
            print("Clave OpenAI: \(Config.apiKey != nil ? "sí" : "NO")")
            let o = Config.outputFolder()
            print("Carpeta de salida: \(o.url.path) (\(o.isDrive ? "Google Drive" : "local"))")
            print("Motor: \(Config.isLocal ? "Whisper local (modelo \(LocalWhisper.modelReady ? "listo" : "sin descargar"))" : "OpenAI \(Config.transcribeModel)") · resumen \(Config.summaryModel)")
            return 0
        case "--transcribe":
            guard args.count > 2 else { return 1 }
            return wait {
                let t = try await Engine.transcribe(file: URL(fileURLWithPath: args[2]), prompt: Engine.vocabularyPrompt)
                print(TextClean.forDictation(t))
            }
        case "--process":
            // --process <mic|-> <sys|-> [carpeta-salida]
            guard args.count > 3 else { print("uso: --process <mic|-> <sys|-> [carpeta]"); return 1 }
            let mic = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
            let sys = args[3] == "-" ? nil : URL(fileURLWithPath: args[3])
            let out = args.count > 4 ? URL(fileURLWithPath: args[4], isDirectory: true) : nil
            return wait {
                let s = MeetingSession(archive: false)
                let t0 = Date()
                s.feedFiles(mic: mic, sys: sys)
                print("Segmentos cortados en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; transcribiendo…")
                let doc = try await s.finalize(audioSources: [mic, sys].compactMap { $0 }, outputDir: out) { print($0) }
                print("Listo en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(doc.path)")
            }
        case "--traducir":
            // --traducir <audio> [salida.wav] [idioma]
            guard args.count > 2 else { print("uso: --traducir <audio> [salida.wav] [idioma]"); return 1 }
            let out = URL(fileURLWithPath: args.count > 3 ? args[3] : NSTemporaryDirectory() + "escriba-traduccion.wav")
            return wait {
                try await TranslateTest.run(input: URL(fileURLWithPath: args[2]), output: out, language: args.count > 4 ? args[4] : Config.translateTo)
            }
        case "--escuchar":
            // --escuchar <entrada> <segundos> <salida.wav>
            guard args.count > 4 else { print("uso: --escuchar <entrada> <segundos> <salida.wav>"); return 1 }
            do { try ListenTest.run(device: args[2], seconds: Double(args[3]) ?? 10, output: URL(fileURLWithPath: args[4])) }
            catch { print("Error: \(error.localizedDescription)"); return 1 }
            return 0
        case "--acelerar":
            // --acelerar <audio> <salida.wav> <velocidad>: prueba del acelerador de voz, sin red
            guard args.count > 4, let rate = Double(args[4]) else { print("uso: --acelerar <audio> <salida.wav> <velocidad>"); return 1 }
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return 1 }
                try file.read(into: buf)
                let x = Mono24Converter().convert(buf)
                let c = TimeCompressor()
                var out: [Float] = []
                var i = 0
                let t0 = Date()
                while i < x.count {
                    let n = min(240, x.count - i)
                    x.withUnsafeBufferPointer { c.append(UnsafeBufferPointer(rebasing: $0[i..<(i + n)])) }
                    i += n
                    while c.step(rate: rate, into: &out) {}
                }
                let cpu = Date().timeIntervalSince(t0)
                var maxDiff: Float = 0
                if rate == 1 { for j in 360..<min(out.count, x.count) { maxDiff = max(maxDiff, abs(out[j] - x[j])) } }
                print(String(format: "entrada %.2f s, salida %.2f s (%.3fx), proceso %.3f s%@", Double(x.count) / kTR, Double(out.count) / kTR,
                             Double(x.count) / Double(max(1, out.count)), cpu, rate == 1 ? String(format: ", diferencia máxima %.6f", maxDiff) : ""))
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: kTR, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                let f = try AVAudioFile(forWriting: URL(fileURLWithPath: args[3]), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                if let b = AVAudioPCMBuffer(pcmFormat: mono24k, frameCapacity: AVAudioFrameCount(out.count)) {
                    b.frameLength = AVAudioFrameCount(out.count)
                    out.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
                    try f.write(from: b)
                }
            } catch { print("Error: \(error.localizedDescription)"); return 1 }
            return 0
        case "--que-microfono":
            // Por cuál micrófono se te escucharía al traducir tu voz, ahora mismo
            let m = AudioDevices.pickRealMic()
            print("tapa cerrada: \(AudioDevices.lidClosed ? "sí" : "no"); preferido: «\(Config.preferredMic)»; del sistema: \(m.system?.name ?? "ninguno"); se usaría: \(m.real?.name ?? "ninguno")")
            return 0
        case "--apps-microfono":
            // Qué apps tienen un micrófono abierto ahora (para no hacer pruebas con sonido en plena llamada)
            let u = AudioDevices.inputUsers()
            print(u.isEmpty ? "ninguna" : u.joined(separator: "\n"))
            return 0
        case "--grabar-app":
            // --grabar-app <pid> <segundos> <salida.wav>: graba solo lo que suena desde ese proceso (prueba)
            guard args.count > 4, let pid = Int32(args[2]), let secs = Double(args[3]) else { print("uso: --grabar-app <pid> <segundos> <salida.wav>"); return 1 }
            guard #available(macOS 14.2, *) else { print("Necesita macOS 14.2"); return 1 }
            let q = DispatchQueue(label: "escriba.grabar")
            let tap = SystemTap(queue: q)
            let conv = MonoConverter(firstChannelOnly: false)
            var all: [Float] = []
            tap.onBuffer = { b in all += conv.convert(b) }
            do {
                try tap.start(mute: false, only: pid)
                Thread.sleep(forTimeInterval: secs)
                tap.stop()
                q.sync {}
                try writeWAV(all, to: URL(fileURLWithPath: args[4]))
                print(String(format: "grabados %.1f s del proceso %d", Double(all.count) / kSR, pid))
            } catch { print("Error: \(error.localizedDescription)"); return 1 }
            return 0
        case "--reproducir":
            // --reproducir <base de la traza> <salida.wav> <nuevo|rapida|anterior>
            guard args.count > 4 else { print("uso: --reproducir <base> <salida.wav> <nuevo|rapida|anterior>"); return 1 }
            do { try TraceReplay.run(base: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]), mode: args[4]) }
            catch { print("Error: \(error.localizedDescription)"); return 1 }
            return 0
        case "--simular":
            // --simular <audio> <salida.wav> [idioma]: lo que se escucharía, en tiempo real
            guard args.count > 3 else { print("uso: --simular <audio> <salida.wav> [idioma]"); return 1 }
            return wait {
                try await TranslateSim.run(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                                           language: args.count > 4 ? args[4] : Config.translateTo)
            }
        case "--probar-microfono-virtual":
            // Baja y revisa el instalador del micrófono virtual, sin instalarlo.
            return wait {
                let pkg = try await VirtualMicInstaller.fetch()
                print("Descargado y verificado: \(pkg.path)")
                print("Comando: \(VirtualMicInstaller.installCommand(pkg))")
            }
        case "--descargar-modelo":
            let d = ModelDownloader()
            var last = -1
            d.onProgress = { p in let pc = Int(p * 10); if pc != last { last = pc; print("\(pc * 10) %") } }
            d.onDone = { err in print(err.map { "Error: \($0.localizedDescription)" } ?? "Modelo listo: \(LocalWhisper.modelURL.path)"); exit(err == nil ? 0 : 1) }
            d.start()
            RunLoop.main.run()
            return 0
        default:
            print("Comandos: --set-key, --check, --transcribe <audio>, --process <mic|-> <sys|-> [carpeta]")
            return 1
        }
    }

    static func wait(_ work: @escaping () async throws -> Void) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do { try await work() } catch { print("Error: \(error.localizedDescription)"); code = 1 }
            sem.signal()
        }
        sem.wait()
        return code
    }
}

let args = CommandLine.arguments
if args.count > 1, args[1].hasPrefix("--"), args[1] != "--autotest", args[1] != "--autotest-traducir", args[1] != "--autotest-voz", args[1] != "--autotest-interprete", args[1] != "--ver-ajustes" {
    let code = CLI.run(args)
    LocalWhisper.shutdown()
    exit(code)
}

let app = NSApplication.shared
if args.contains("--ver-ajustes") {   // prueba: solo la pantalla de bienvenida, sin dictado ni ícono
    let w = SetupWindow()
    w.onFinish = { print("Guardado"); exit(0) }
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { w.show() }
    if let shot = ProcessInfo.processInfo.environment["ESCRIBA_CAPTURA"] {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { w.snapshot(to: URL(fileURLWithPath: shot)); exit(0) }
    }
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
