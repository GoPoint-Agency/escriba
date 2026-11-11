import Foundation

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

struct Tarea: Codable {
    var responsable: String?
    var tarea: String
    var plazo: String?
}

struct Resumen: Codable {
    var titulo: String
    var cliente: String?
    var resumen: String
    var puntos_clave: [String]?
    var acuerdos: [String]?
    var tareas: [Tarea]?
    var participantes: [String]?
}

enum OpenAI {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    static func transcribe(file: URL, prompt: String?, model: String = Config.transcribeModel) async throws -> String {
        do {
            return try await transcribeOnce(file: file, prompt: prompt, model: model)
        } catch EscribaError.http(let code, let msg) where (code == 400 || code == 404) && msg.contains("model") && model != Config.fallbackTranscribeModel {
            log("Modelo \(model) rechazado, uso \(Config.fallbackTranscribeModel)")
            return try await transcribeOnce(file: file, prompt: prompt, model: Config.fallbackTranscribeModel)
        }
    }

    private static func transcribeOnce(file: URL, prompt: String?, model: String) async throws -> String {
        guard let key = Config.apiKey else { throw EscribaError.noKey }
        let boundary = "escriba-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("language", "es")
        field("response_format", "json")
        if let p = prompt, !p.isEmpty { field("prompt", p) }
        let mime = file.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/mp4"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: req, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw EscribaError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summarize(transcript: String, durationText: String) async throws -> Resumen {
        let me = Config.userName, others = Config.othersLabel
        let system = """
        Resumes reuniones de trabajo de \(me)\(Config.userDescription.isEmpty ? "" : " (\(Config.userDescription))").
        En la transcripción, "\(me)" es lo que dijo \(me) por su micrófono y "\(others)" es el audio de los demás participantes (puede ser más de una persona). Algunas líneas ya traen el nombre real de quien habló en vez de "\(others)". Si por el contexto se entiende quién habla, usa su nombre en el resumen.
        Escribe en español de Chile, claro y directo. No uses guion largo ni guion medio como puntuación. No uses signos de apertura (¿ ¡).
        No inventes nada que no esté en la transcripción. Si algo no se dijo, no lo pongas.
        Responde SOLO un objeto JSON con estas claves:
        "cliente": nombre de la empresa cliente, prospecto o contraparte externa de la que trata la reunión.\(Config.clients.isEmpty ? "" : " Si coincide con uno de esta lista, escríbelo exactamente así: \(Config.clients.joined(separator: "; ")).") Si es otra empresa, su nombre tal como se dijo. Déjalo vacío si es una reunión interna o si no se puede saber;
        "titulo": máximo 8 palabras, sin fecha y sin repetir el nombre del cliente;
        "resumen": un párrafo de 3 a 6 frases;
        "puntos_clave": lista de frases cortas;
        "acuerdos": lista de lo que quedó decidido;
        "tareas": lista de objetos {"responsable", "tarea", "plazo"} (plazo vacío si no se dijo). Como responsable usa el nombre real de la persona si se deduce de la conversación (por ejemplo, si \(me) la saludó por su nombre); usa "\(others)" solo si no hay forma de saberlo;
        "participantes": lista de nombres que se mencionan como presentes.
        """
        let user = "Duración: \(durationText)\n\nTranscripción:\n\(transcript)"
        return try JSONDecoder().decode(Resumen.self, from: try await chatJSON(system: system, user: user))
    }

    /// Mira la conversación y dice quién de los demás dijo cada línea, solo cuando se puede deducir.
    /// Recibe las líneas numeradas y devuelve número de línea -> nombre.
    static func identifySpeakers(numbered: String) async throws -> [Int: String] {
        let me = Config.userName, others = Config.othersLabel
        let system = """
        Te paso la transcripción de una reunión online de \(me). Las líneas de "\(me)" son de su micrófono. Las líneas de "\(others)" son el audio del computador: puede ser una sola persona o varias.
        Tu tarea: decir quién dijo cada línea de "\(others)", usando solo lo que se escucha en la conversación:
        1. Alguien se presenta ("hola, soy Carla", "habla Pedro de Antares").
        2. \(me) u otro le habla por su nombre y esa persona contesta en la línea siguiente.
        3. Si se nota que del otro lado hay una sola persona y su nombre se supo, todas las líneas de "\(others)" son de ella.
        4. Si en una parte hablan varias personas y no se distingue cuál dijo esa línea, no la pongas.
        Nunca inventes nombres ni uses "\(me)". Si no hay pruebas claras para una línea, no la incluyas. Escribe el nombre como se dijo (solo nombre, o nombre y apellido si se dijo).
        Responde SOLO un objeto JSON: {"hablantes": {"<número de línea>": "<nombre>", ...}}. Si no se puede saber ninguno, {"hablantes": {}}.
        """
        let data = try await chatJSON(system: system, user: numbered)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = j["hablantes"] as? [String: Any] else { return [:] }
        var out: [Int: String] = [:]
        for (k, v) in h {
            guard let i = Int(k.filter(\.isNumber)), let name = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.lowercased() != others.lowercased(), name.lowercased() != me.lowercased() else { continue }
            out[i] = name
        }
        return out
    }

    private static func chatJSON(system: String, user: String) async throws -> Data {
        guard let key = Config.apiKey else { throw EscribaError.noKey }
        let payload: [String: Any] = [
            "model": Config.summaryModel,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "response_format": ["type": "json_object"],
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw EscribaError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String,
              let cdata = content.data(using: .utf8)
        else { throw EscribaError.other("Respuesta inesperada de OpenAI") }
        return cdata
    }
}

enum TextClean {
    /// Frases que los modelos de transcripción inventan sobre silencio o ruido.
    static let hallucinations = [
        "subtítulos realizados por la comunidad de amara.org", "gracias por ver el video", "gracias por ver",
        "suscríbete", "subtitulado por", "amara.org", "¡gracias!", "gracias.",
    ]

    static func isHallucination(_ t: String) -> Bool {
        let n = t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if n.isEmpty { return true }
        for h in hallucinations {
            let hn = h.trimmingCharacters(in: .punctuationCharacters)
            if n == hn || (n.contains(hn) && n.count < hn.count + 12 && hn.count > 10) { return true }
        }
        if n.hasPrefix("vocabulario") { return true }
        return false
    }

    static func forDictation(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if Config.stripOpeningMarks { s = s.replacingOccurrences(of: "¿", with: "").replacingOccurrences(of: "¡", with: "") }
        return s
    }
}
