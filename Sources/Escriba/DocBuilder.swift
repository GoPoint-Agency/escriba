import Foundation

enum DocBuilder {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(title: String, date: Date, duration: String, resumen: Resumen?, lines: [MeetingSession.Line],
                     failedCount: Int, audioName: String?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CL")
        df.dateFormat = "EEEE d 'de' MMMM yyyy, HH:mm"
        var h = """
        <html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>
        body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; color: #222; }
        h1 { font-size: 18pt; margin-bottom: 2pt; }
        h2 { font-size: 13pt; margin-top: 16pt; color: #1a3d6d; }
        .meta { color: #666; font-size: 10pt; }
        .t { color: #888; font-size: 9pt; }
        .who { font-weight: bold; }
        </style></head><body>
        <h1>\(esc(title))</h1>
        <p class="meta">\(esc(df.string(from: date).prefix(1).uppercased() + df.string(from: date).dropFirst())) · \(esc(duration))\(audioName.map { " · Audio: \(esc($0))" } ?? "")</p>
        """
        if failedCount > 0 {
            h += "<p><b>Ojo:</b> \(failedCount) fragmentos no se pudieron transcribir. El audio completo quedó guardado junto a este documento.</p>"
        }
        if let r = resumen {
            if let c = r.cliente, !c.isEmpty { h += "<p class=\"meta\">Cliente: \(esc(c))</p>" }
            h += "<h2>Resumen</h2><p>\(esc(r.resumen))</p>"
            if let p = r.participantes, !p.isEmpty { h += "<p class=\"meta\">Participantes: \(esc(p.joined(separator: ", ")))</p>" }
            func list(_ name: String, _ items: [String]?) {
                guard let items, !items.isEmpty else { return }
                h += "<h2>\(name)</h2><ul>" + items.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
            }
            list("Puntos clave", r.puntos_clave)
            list("Acuerdos", r.acuerdos)
            if let t = r.tareas, !t.isEmpty {
                h += "<h2>Tareas</h2><ul>"
                for x in t {
                    var s = ""
                    if let who = x.responsable, !who.isEmpty { s += "<b>\(esc(who)):</b> " }
                    s += esc(x.tarea)
                    if let p = x.plazo, !p.isEmpty { s += " <i>(\(esc(p)))</i>" }
                    h += "<li>\(s)</li>"
                }
                h += "</ul>"
            }
        } else if !lines.isEmpty {
            h += Config.apiKey == nil
                ? "<p><i>Sin resumen: con una clave de OpenAI (menú de Escriba, Ajustes) cada reunión trae además resumen, acuerdos, tareas y los nombres de quienes hablaron.</i></p>"
                : "<p><i>No se pudo generar el resumen. La transcripción completa está abajo.</i></p>"
        }
        h += "<h2>Transcripción</h2>"
        if lines.isEmpty { h += "<p><i>No se detectó conversación en la grabación.</i></p>" }
        for l in lines {
            h += "<p><span class=\"t\">[\(MeetingSession.clock(l.start))]</span> <span class=\"who\">\(esc(l.who)):</span> \(esc(l.text))</p>"
        }
        h += "</body></html>"
        return h
    }
}
