import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

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
        case "--apps-captura":
            // Qué apps ve la captura de audio del sistema (para saber si se puede dejar fuera a Intérprete)
            return wait {
                let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                for a in c.applications where a.bundleIdentifier.contains("gopoint") || a.applicationName.contains("nterprete") || a.applicationName.contains("ntérprete") {
                    print("\(a.processID) [\(a.bundleIdentifier)] \(a.applicationName)")
                }
                print("\(c.applications.count) apps en total")
            }
        case "--probar-teclas":
            // Prueba la lógica de las teclas del dictado sin tocar el teclado ni el micrófono.
            let o = HoldKeys.rightOption, s = HoldKeys.rightShift, ls = HoldKeys.leftShift, cmd = HoldKeys.command
            typealias Paso = (tecla: UInt16?, flags: UInt, espera: HoldKeys.Action)   // tecla nil = tecla normal
            let casos: [(String, [Paso], Bool)] = [
                ("solo ⌥ derecha: dicta en español", [(61, o, .start), (61, 0, .finish)], false),
                ("⇧ derecha y después ⌥ derecha: traducido", [(60, s, .none), (61, o | s, .start), (61, s, .finish), (60, 0, .none)], true),
                ("⌥ derecha y después ⇧ derecha: traducido", [(61, o, .start), (60, o | s, .translateOn), (60, o, .none), (61, 0, .finish)], true),
                ("suelta ⇧ antes que ⌥: sigue traducido", [(61, o, .start), (60, o | s, .translateOn), (60, o, .none), (61, 0, .finish)], true),
                ("⇧ izquierda con ⌥ derecha: no parte", [(56, ls, .none), (61, o | ls, .none), (61, ls, .none)], false),
                ("⌘ con ⌥ derecha ya apretada: cancela", [(61, o, .start), (55, o | cmd, .cancel), (61, cmd, .finish)], false),
                ("⌥ + ⇧ + letra: es un símbolo, cancela", [(61, o, .start), (60, o | s, .translateOn), (nil, o | s, .cancel), (61, s, .finish)], true),
                ("⇧ derecha sola: no hace nada", [(60, s, .none), (60, 0, .none)], false),
            ]
            var fallas = 0
            for (nombre, pasos, traducido) in casos {
                var k = HoldKeys()
                var bien = true
                for p in pasos {
                    let a = p.tecla.map { k.flagsChanged(keyCode: $0, raw: p.flags) } ?? k.keyPressed()
                    if a != p.espera { bien = false; print("   esperaba \(p.espera), salió \(a)") }
                }
                if k.translate != traducido { bien = false; print("   traducido=\(k.translate), esperaba \(traducido)") }
                if k.down { bien = false; print("   quedó apretada") }
                print("\(bien ? "OK   " : "FALLA") \(nombre)")
                if !bien { fallas += 1 }
            }
            print(fallas == 0 ? "Las \(casos.count) pasaron" : "\(fallas) fallaron")
            return fallas == 0 ? 0 : 1
        case "--traducir-texto":
            // --traducir-texto "<texto>" [idioma]
            guard args.count > 2 else { print("uso: --traducir-texto \"<texto>\" [idioma]"); return 1 }
            return wait {
                let t0 = Date()
                let out = try await OpenAI.translate(args[2], to: args.count > 3 ? args[3] : Config.dictationLanguage)
                print(String(format: "[%.1f s] %@", Date().timeIntervalSince(t0), out))
            }
        case "--dictar-traducido":
            // --dictar-traducido <audio> [idioma]: lo mismo que hace el dictado con ⌥ + ⇧, sin pegar nada
            guard args.count > 2 else { print("uso: --dictar-traducido <audio> [idioma]"); return 1 }
            return wait {
                let t0 = Date()
                let es = TextClean.forDictation(try await Engine.transcribe(file: URL(fileURLWithPath: args[2]), prompt: Engine.vocabularyPrompt))
                let t1 = Date()
                let out = try await OpenAI.translate(es, to: args.count > 3 ? args[3] : Config.dictationLanguage)
                print("Dictado: \(es)")
                print("Traducido: \(out)")
                print(String(format: "Transcribir %.1f s, traducir %.1f s", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
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
if args.count > 1, args[1].hasPrefix("--"), args[1] != "--autotest", args[1] != "--ver-ajustes" {
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
