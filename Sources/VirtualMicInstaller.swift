import Foundation

/// Instala el micrófono virtual (BlackHole 2ch, de Existential Audio) sin que el usuario salga de Escriba:
/// lo baja del sitio oficial, revisa que sea el original y lo instala pidiendo la clave del Mac una vez.
enum VirtualMicInstaller {
    static let teamID = "Q5C99V536K"   // Existential Audio Inc.
    static let fallbackURL = "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg"
    static let fallbackSHA = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let website = URL(string: "https://existential.audio/blackhole/")!

    enum Result { case installed, needsRestart, canceled, failed(String) }

    private static func run(_ tool: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }

    /// Dónde está la versión vigente y su huella. Si no se puede consultar, se usa la conocida.
    private static func source() async -> (url: URL, sha: String) {
        if let u = URL(string: "https://formulae.brew.sh/api/cask/blackhole-2ch.json"),
           let (d, _) = try? await URLSession.shared.data(from: u),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = j["url"] as? String, s.hasPrefix("https://existential.audio/"), let url = URL(string: s),
           let sha = j["sha256"] as? String, sha.count == 64 {
            return (url, sha)
        }
        return (URL(string: fallbackURL)!, fallbackSHA)
    }

    /// Baja y revisa el instalador. Devuelve la ruta lista para instalar.
    static func fetch() async throws -> URL {
        let src = await source()
        let (tmp, resp) = try await URLSession.shared.download(from: src.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw EscribaError.other("No pude descargar el micrófono virtual.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("escriba-microfono", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = dir.appendingPathComponent("BlackHole2ch.pkg")
        try FileManager.default.moveItem(at: tmp, to: pkg)
        guard try ModelDownloader.sha256(pkg) == src.sha else { throw EscribaError.other("La descarga del micrófono virtual llegó dañada.") }
        let sig = run("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
        guard sig.code == 0, sig.out.contains("(\(teamID))"), sig.out.contains("Developer ID Installer: Existential Audio") else {
            throw EscribaError.other("El instalador del micrófono virtual no viene firmado por su fabricante.")
        }
        return pkg
    }

    /// Comando que instala el paquete. Va entre comillas simples; la ruta temporal no trae comillas.
    /// Después de instalar se reinicia el servicio de audio del Mac: sin eso el micrófono nuevo no aparece
    /// hasta reiniciar el computador (el audio se corta un par de segundos).
    static func installCommand(_ pkg: URL) -> String {
        "/usr/sbin/installer -pkg '\(pkg.path)' -target / && (/usr/bin/killall coreaudiod || true)"
    }

    static func install() async -> Result {
        let pkg: URL
        do { pkg = try await fetch() } catch { return .failed(error.localizedDescription) }
        guard !pkg.path.contains("'"), !pkg.path.contains("\"") else { return .failed("Ruta temporal inesperada.") }
        let script = "do shell script \"\(installCommand(pkg))\" with prompt \"Escriba va a instalar el micrófono virtual (BlackHole) para que te escuchen traducido.\" with administrator privileges"
        let r = run("/usr/bin/osascript", ["-e", script])
        try? FileManager.default.removeItem(at: pkg.deletingLastPathComponent())
        if r.code == 0 {
            // El sistema tarda unos segundos en mostrar el dispositivo nuevo.
            for _ in 0..<40 {
                if AudioDevices.virtualMic != nil { return .installed }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            log("Micrófono virtual: instalado, pero no aparece sin reiniciar")
            return .needsRestart
        }
        if r.out.contains("-128") || r.out.localizedCaseInsensitiveContains("cancel") { return .canceled }
        log("Micrófono virtual: la instalación falló: \(r.out.prefix(300))")
        return .failed("La instalación no terminó.")
    }
}
