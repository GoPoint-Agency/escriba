import AppKit

/// Pantalla de bienvenida y ajustes: nombre, con qué transcribir y la clave de OpenAI.
final class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let nameField = NSTextField()
    private let localRadio = NSButton(radioButtonWithTitle: "Whisper en este Mac: gratis y privado (descarga única de 550 MB)", target: nil, action: nil)
    private let openaiRadio = NSButton(radioButtonWithTitle: "OpenAI: un poco más preciso, cobra por minuto (necesita clave)", target: nil, action: nil)
    private let keyField = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let saveButton = NSButton(title: "Guardar", target: nil, action: nil)
    private var downloader: ModelDownloader?
    var onFinish: (() -> Void)?

    func show() {
        if window == nil { build() }
        nameField.stringValue = Config.settings["nombre"] as? String ?? ""
        (Config.isLocal || !Config.configured ? localRadio : openaiRadio).state = .on
        keyField.stringValue = Config.settings["openai_api_key"] as? String ?? ""
        status.stringValue = ""
        progress.isHidden = true
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Para pruebas: guarda una imagen de la ventana.
    func snapshot(to url: URL) {
        guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func label(_ s: String, bold: Bool = false, small: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: small ? 11 : 13)
        if small { l.textColor = .secondaryLabelColor }
        return l
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Escriba"
        window.isReleasedWhenClosed = false
        window.delegate = self

        localRadio.target = self; localRadio.action = #selector(radioChanged)
        openaiRadio.target = self; openaiRadio.action = #selector(radioChanged)
        nameField.placeholderString = "Por ejemplo: Eduardo"
        keyField.placeholderString = "sk-…"
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.isHidden = true
        status.textColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Configura Escriba")
        title.font = .boldSystemFont(ofSize: 17)
        let stack = NSStackView(views: [
            title,
            label("Graba tus reuniones y las transcribe. Para dictar en cualquier app, mantén apretada la tecla ⌥ de la derecha.", small: true),
            label("Tu nombre (así aparece en las transcripciones)", bold: true), nameField,
            label("Con qué transcribir", bold: true), localRadio, openaiRadio,
            label("Clave de OpenAI (opcional con Whisper)", bold: true), keyField,
            label("Con clave, cada reunión trae además resumen, acuerdos, tareas y los nombres de quienes hablaron. Cuesta cerca de un centavo de dólar por reunión. Sin clave, queda la transcripción completa.", small: true),
            progress, status, saveButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.setCustomSpacing(16, after: stack.views[1])
        stack.setCustomSpacing(14, after: nameField)
        stack.setCustomSpacing(14, after: openaiRadio)
        for v in [nameField, keyField, progress, status] {
            v.widthAnchor.constraint(equalToConstant: 472).isActive = true
        }
        for v in stack.views where v is NSTextField && v !== nameField && v !== keyField {
            (v as! NSTextField).preferredMaxLayoutWidth = 472
        }
        window.contentView = stack
    }

    @objc private func radioChanged(_ sender: NSButton) {
        localRadio.state = sender === localRadio ? .on : .off
        openaiRadio.state = sender === openaiRadio ? .on : .off
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = localRadio.state == .on
        guard !name.isEmpty else { status.stringValue = "Escribe tu nombre."; return }
        if !local && key.isEmpty { status.stringValue = "Para transcribir con OpenAI hace falta la clave. Si no tienes, elige Whisper."; return }
        saveButton.isEnabled = false
        status.stringValue = key.isEmpty ? "" : "Revisando la clave…"
        Task { @MainActor in
            if !key.isEmpty, let problem = await SetupWindow.checkKey(key) {
                self.status.stringValue = problem
                self.saveButton.isEnabled = true
                return
            }
            do {
                try Config.update(["nombre": name, "motor": local ? "local" : "openai",
                                   "openai_api_key": key.isEmpty ? nil : key, "configurado": true])
            } catch {
                self.status.stringValue = "No pude guardar: \(error.localizedDescription)"
                self.saveButton.isEnabled = true
                return
            }
            if local && !LocalWhisper.modelReady { self.download() } else { self.finish() }
        }
    }

    private func download() {
        status.stringValue = "Descargando Whisper (550 MB). Puede tardar unos minutos; no cierres esta ventana."
        progress.isHidden = false
        progress.doubleValue = 0
        let d = ModelDownloader()
        downloader = d
        d.onProgress = { [weak self] p in
            self?.progress.doubleValue = p
            self?.status.stringValue = "Descargando Whisper: \(Int(p * 100)) %. No cierres esta ventana."
        }
        d.onDone = { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloader = nil
                if let err {
                    self.status.stringValue = "La descarga falló: \(err.localizedDescription). Revisa internet y toca Guardar de nuevo."
                    self.progress.isHidden = true
                    self.saveButton.isEnabled = true
                } else {
                    self.finish()
                }
            }
        }
        d.start()
    }

    private func finish() {
        status.stringValue = "Listo."
        saveButton.isEnabled = true
        window.orderOut(nil)
        onFinish?()
    }

    /// nil si la clave sirve; si no, el motivo en palabras simples.
    static func checkKey(_ key: String) async -> String? {
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
