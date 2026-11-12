import Foundation
import Security

/// Ajustes de la app. Se pueden cambiar en
/// ~/Library/Application Support/<app>/config.json sin recompilar. `kAppFolder` y `kLogFile` los define cada app.
enum Config {
    static let appSupport: URL = {
        if let d = ProcessInfo.processInfo.environment["ESCRIBA_DIR"] {   // solo para pruebas
            let u = URL(fileURLWithPath: d, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kAppFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var sessionsDir: URL {
        let u = appSupport.appendingPathComponent("sesiones", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var settings: [String: Any] {
        let url = appSupport.appendingPathComponent("config.json")
        if let d = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
        return [:]
    }

    static var userName: String {
        let n = (settings["nombre"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Yo" : n
    }
    /// Quién es el usuario, para darle contexto al resumen (opcional).
    static var userDescription: String { settings["descripcion"] as? String ?? "" }
    /// Ya pasó por la pantalla de bienvenida.
    static var configured: Bool { settings["configurado"] as? Bool ?? false }
    /// "local" (Whisper en el Mac) u "openai". ESCRIBA_MOTOR lo cambia para pruebas.
    static var engine: String {
        ProcessInfo.processInfo.environment["ESCRIBA_MOTOR"] ?? (settings["motor"] as? String ?? "openai")
    }
    static var isLocal: Bool { engine == "local" }
    static var othersLabel: String { settings["etiqueta_otros"] as? String ?? "Otros" }
    static var vocabulary: String {
        settings["vocabulario"] as? String ?? ""
    }
    static var transcribeModel: String { settings["modelo_transcripcion"] as? String ?? "gpt-transcribe" }
    static let fallbackTranscribeModel = "gpt-4o-transcribe"
    static var summaryModel: String { settings["modelo_resumen"] as? String ?? "gpt-5.4-mini" }
    /// Idioma al que se traduce en vivo lo que se escucha.
    static var translateTo: String { settings["traducir_a"] as? String ?? "es" }
    /// Idioma en que te escuchan los demás cuando traduces tu voz.
    static var voiceTo: String { settings["mi_voz_a"] as? String ?? "en" }
    /// Nombre (o parte) del micrófono virtual por donde sale tu voz traducida.
    static var virtualMicName: String { settings["microfono_virtual"] as? String ?? "BlackHole" }
    /// Idiomas para el dictado traducido (⌥ + ⇧ derechas): código, nombre en el menú y nombre para el traductor.
    static let dictationLanguages: [(code: String, name: String, prompt: String)] = [
        ("en", "Inglés", "inglés"), ("pt", "Portugués", "portugués de Brasil"), ("de", "Alemán", "alemán"),
        ("fr", "Francés", "francés"), ("it", "Italiano", "italiano"),
    ]
    static var dictationLanguage: String {
        let c = settings["dictado_idioma"] as? String ?? "en"
        return dictationLanguages.contains { $0.code == c } ? c : "en"
    }
    /// Micrófono que se prefiere para traducir tu voz (parte del nombre). Vacío: el del sistema.
    static var preferredMic: String { settings["microfono"] as? String ?? "" }
    /// Presentar el micrófono virtual envuelto en un dispositivo agrupado (para apps que esconden los virtuales).
    static var useBridge: Bool { settings["microfono_puente"] as? Bool ?? true }
    static var showCaptions: Bool { settings["subtitulos"] as? Bool ?? false }
    /// Volumen al que queda el audio original mientras se traduce (0 a 1). Con 1 no se toca.
    static var originalVolume: Double { settings["volumen_original"] as? Double ?? 0.10 }
    /// Volumen del original mientras suena la voz traducida.
    static var originalVolumeDucked: Double { settings["volumen_original_con_voz"] as? Double ?? originalVolume * 0.4 }
    /// Si la red tropieza y la traducción se atrasa, acelerar un poco la voz hasta ponerse al día.
    static var catchUp: Bool { settings["voz_alcanza"] as? Bool ?? true }
    static var clients: [String] { settings["clientes"] as? [String] ?? [] }
    static var stripOpeningMarks: Bool { settings["quitar_signos_apertura"] as? Bool ?? true }

    /// Ajustes de la otra app de la familia (Escriba o Interprete), solo para leer.
    static func sibling(_ folder: String) -> [String: Any] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent("config.json")
        if let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
        return [:]
    }

    /// Primera vez que se abre Intérprete: trae los ajustes de traducción que estaban en Escriba.
    static func adoptFromEscriba() {
        guard kAppFolder != "Escriba", !FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("config.json").path) else { return }
        let old = sibling("Escriba")
        var mine: [String: Any?] = [:]
        for k in ["traducir_a", "mi_voz_a", "microfono_virtual", "microfono", "microfono_puente", "subtitulos",
                  "volumen_original", "volumen_original_con_voz", "voz_alcanza"] {
            if let v = old[k] { mine[k] = v }
        }
        mine["configurado"] = true
        try? update(mine)
    }

    private static var cachedKey: String?
    private static let keyLock = NSLock()

    /// Se lee una vez y queda en memoria: leer el llavero en paralelo a veces falla.
    static var apiKey: String? {
        keyLock.lock(); defer { keyLock.unlock() }
        if ProcessInfo.processInfo.environment["ESCRIBA_SIN_CLAVE"] != nil { return nil }
        if let k = cachedKey { return k }
        // Primero el archivo protegido (sin avisos del llavero cada vez que se recompila).
        var k: String?
        if let v = settings["openai_api_key"] as? String, !v.isEmpty { k = v }
        if k == nil, let v = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !v.isEmpty { k = v }
        // Intérprete usa la clave que ya esté puesta en Escriba, para no pedirla dos veces.
        if k == nil, kAppFolder != "Escriba", let v = sibling("Escriba")["openai_api_key"] as? String, !v.isEmpty { k = v }
        if k == nil, let v = Keychain.get(), !v.isEmpty { k = v }
        cachedKey = k
        return k
    }

    /// Guarda cambios en config.json (solo tu usuario puede leerlo).
    static func update(_ changes: [String: Any?]) throws {
        let url = appSupport.appendingPathComponent("config.json")
        var j = settings
        for (k, v) in changes { if let v { j[k] = v } else { j.removeValue(forKey: k) } }
        try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        keyLock.lock(); cachedKey = nil; keyLock.unlock()
    }

    /// Carpeta de Google Drive (vía Google Drive para escritorio) o, si no está, ~/Documents/Reuniones.
    static func outputFolder() -> (url: URL, isDrive: Bool) {
        let fm = FileManager.default
        if let custom = settings["carpeta_salida"] as? String, !custom.isEmpty {
            let u = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return (u, u.path.contains("CloudStorage/GoogleDrive"))
        }
        let cs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        var drives = ((try? fm.contentsOfDirectory(atPath: cs.path)) ?? []).filter { $0.hasPrefix("GoogleDrive-") }
        drives.sort { a, b in a.contains("gopointagency") && !b.contains("gopointagency") }
        for d in drives {
            for root in ["Mi unidad", "My Drive"] {
                let r = cs.appendingPathComponent(d).appendingPathComponent(root, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: r.path, isDirectory: &isDir), isDir.boolValue {
                    let out = r.appendingPathComponent("Reuniones", isDirectory: true)
                    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                    return (out, true)
                }
            }
        }
        let local = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Reuniones", isDirectory: true)
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        return (local, false)
    }
}

enum Keychain {
    static let service = "Escriba"
    static let account = "openai"

    static func get() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Escriba: clave de OpenAI"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let url = Config.appSupport.appendingPathComponent(kLogFile)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
