import Foundation
import CryptoKit

enum EscribaError: LocalizedError {
    case noKey
    case http(Int, String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Falta la clave de OpenAI"
        case .http(let c, let m): return "OpenAI respondió \(c): \(m.prefix(200))"
        case .other(let m): return m
        }
    }
}

/// 75 -> "01:15"; 3700 -> "1:01:40".
func reloj(_ t: Double) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

/// Huella SHA-256 de un archivo, leyéndolo por partes.
func huellaSHA256(de url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

enum OpenAIKey {
    /// nil si la clave sirve; si no, el motivo en palabras simples.
    static func check(_ key: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return nil
            case 401: return "OpenAI no reconoce esa clave. Revísala y vuelve a pegarla."
            case let c: return "OpenAI respondió con un error (\(c)). Intenta de nuevo en un rato."
            }
        } catch {
            return "No pude conectarme con OpenAI. Revisa internet."
        }
    }
}
