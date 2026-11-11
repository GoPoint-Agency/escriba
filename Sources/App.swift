import AppKit
import AVFoundation
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var capture: LiveCapture?
    private var recordStart = Date()
    private var tick: Timer?
    private let dictation = Dictation()
    private var dictState: Dictation.State = .idle
    private var processing: [String] = []   // mensajes de reuniones en proceso
    private var lastDoc: URL?
    private var busyDirs = Set<String>()
    private let setup = SetupWindow()
    private var translator: LiveTranslator?
    private var translatorStarting = false
    private var voice: VoiceTranslator?
    private var voiceStarting = false
    private var micInstalling = false
    private let captions = CaptionPanel()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        refreshIcon()

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        dictation.onState = { [weak self] s in self?.dictState = s; self?.refreshIcon() }
        dictation.onMessage = { [weak self] m in self?.notify("Dictado", m) }
        // En la prueba de traducción no se instala el dictado: habría dos Escriba escribiendo a la vez.
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--autotest-") }) { dictation.install() }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        AudioDevices.restoreMicIfNeeded()
        installEditMenu()
        if !Config.configured { setup.show() } else if let m = Engine.missing { notify("Escriba", m) }
        log("Escriba iniciado (micrófono=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized), accesibilidad=\(AXIsProcessTrusted()), pantalla=\(CGPreflightScreenCaptureAccess()))")
        if CommandLine.arguments.contains("--autotest-voz") {   // prueba: traduce 25 s de voz (o de ESCRIBA_VOZ_ARCHIVO)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.toggleVoice() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + AppDelegate.testSeconds(17)) {
                if self.voice != nil { self.toggleVoice() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            }
        }
        if CommandLine.arguments.contains("--autotest-interprete") {   // prueba: los dos sentidos 22 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.toggleInterpreter() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + AppDelegate.testSeconds(22)) {
                log("Prueba: traductor=\(self.translator != nil) voz=\(self.voice != nil)")
                self.toggleInterpreter()
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            }
        }
        if CommandLine.arguments.contains("--autotest-traducir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.autotestTranslate(seconds: AppDelegate.testSeconds(30)) }
        }
        if CommandLine.arguments.contains("--autotest") {
            // Prueba: graba 20 segundos sola y procesa.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startRecording() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 24) { if let c = self.capture { self.stopRecording(c) } }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        AudioDevices.restoreMicIfNeeded()   // por si se sale con la traducción de voz activa
        LocalWhisper.shutdown()
    }

    /// Duración de las pruebas automáticas (ESCRIBA_PRUEBA_S la cambia).
    static func testSeconds(_ normal: Double) -> Double {
        Double(ProcessInfo.processInfo.environment["ESCRIBA_PRUEBA_S"] ?? "") ?? normal
    }

    /// Prueba: traduce durante unos segundos lo que suene en el Mac.
    private func autotestTranslate(seconds: Double) {
        toggleTranslate()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.translator != nil { self.toggleTranslate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
        }
    }

    // MARK: Ícono

    private func refreshIcon() {
        guard let b = item.button else { return }
        var symbol = "waveform"
        var tint: NSColor? = nil
        var title = ""
        if capture != nil {
            symbol = "record.circle.fill"; tint = .systemRed
            title = " " + MeetingSession.clock(Date().timeIntervalSince(recordStart))
        }
        if (translator != nil || voice != nil) && capture == nil { symbol = "globe" }
        switch dictState {
        case .listening: symbol = "mic.fill"; tint = .systemRed
        case .transcribing: symbol = "ellipsis.circle"
        case .idle: if capture == nil && !processing.isEmpty { symbol = "doc.text.magnifyingglass" }
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Escriba")
        img?.isTemplate = true
        b.image = img
        b.contentTintColor = tint
        b.title = title
        b.imagePosition = .imageLeading
    }

    // MARK: Menú

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if capture != nil {
            m.addItem(withTitle: "Detener y transcribir reunión", action: #selector(toggleRecording), keyEquivalent: "").target = self
            let t = NSMenuItem(title: "Grabando: \(MeetingSession.clock(Date().timeIntervalSince(recordStart)))", action: nil, keyEquivalent: "")
            t.isEnabled = false
            m.addItem(t)
        } else {
            m.addItem(withTitle: "Grabar reunión", action: #selector(toggleRecording), keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        if Config.apiKey != nil, AudioDevices.virtualMic != nil {
            let both = translator != nil && voice != nil
            let busy = translatorStarting || voiceStarting
            let i = NSMenuItem(title: both ? "Detener modo intérprete" : (busy ? "Conectando el modo intérprete…" : "Modo intérprete: traducir en los dos sentidos"),
                               action: busy ? nil : #selector(toggleInterpreter), keyEquivalent: "")
            i.target = self
            i.isEnabled = !busy
            i.toolTip = "Tú escuchas en español y a ti te escuchan en inglés. Usa audífonos. Cuesta cerca de 4 dólares por hora."
            m.addItem(i)
        }
        if let t = translator {
            m.addItem(withTitle: "Detener traducción", action: #selector(toggleTranslate), keyEquivalent: "").target = self
            let secs = Date().timeIntervalSince(t.startDate)
            let cost = String(format: "%.2f", secs / 60 * TranslateSocket.dollarsPerMinute).replacingOccurrences(of: ".", with: ",")
            let info = NSMenuItem(title: "Traduciendo: \(MeetingSession.clock(secs)) (cerca de US$ \(cost))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
        } else if translatorStarting {
            let i = NSMenuItem(title: "Conectando la traducción…", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        } else if Config.apiKey != nil {
            let i = NSMenuItem(title: "Traducir al español lo que escucho", action: #selector(toggleTranslate), keyEquivalent: "")
            i.target = self
            i.toolTip = "Usa audífonos. La voz en español sale por OpenAI y cuesta cerca de 2 dólares por hora."
            m.addItem(i)
        } else {
            let i = NSMenuItem(title: "Traducción en vivo: necesita la clave de OpenAI", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        if Config.apiKey != nil, #available(macOS 14.2, *) {
            // Cuánto se oye a la otra persona por debajo de la traducción.
            let vol = NSMenuItem(title: "Volumen de la voz original", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = Config.originalVolume
            for (k, p) in AppDelegate.originalPresets.enumerated() {
                let i = NSMenuItem(title: p.name, action: #selector(setOriginalVolume(_:)), keyEquivalent: "")
                i.target = self
                i.tag = k
                i.state = abs(p.idle - current) < 0.011 ? .on : .off
                sub.addItem(i)
            }
            vol.submenu = sub
            m.addItem(vol)
        }
        if let v = voice {
            m.addItem(withTitle: "Detener traducción de mi voz", action: #selector(toggleVoice), keyEquivalent: "").target = self
            let secs = Date().timeIntervalSince(v.startDate)
            let cost = String(format: "%.2f", secs / 60 * TranslateSocket.dollarsPerMinute).replacingOccurrences(of: ".", with: ",")
            let info = NSMenuItem(title: "Te escuchan en inglés: \(MeetingSession.clock(secs)) (cerca de US$ \(cost)). Micrófono en la reunión: \(v.deviceName)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
        } else if voiceStarting {
            let i = NSMenuItem(title: "Conectando la traducción de tu voz…", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        } else if Config.apiKey != nil {
            if AudioDevices.virtualMic != nil {
                let i = NSMenuItem(title: "Traducir mi voz al inglés para los demás", action: #selector(toggleVoice), keyEquivalent: "")
                i.target = self
                i.toolTip = "Escriba cambia el micrófono del sistema mientras dura. Cuesta cerca de 2 dólares por hora."
                m.addItem(i)
            } else {
                let i = NSMenuItem(title: micInstalling ? "Instalando el micrófono virtual…" : "Traducir mi voz: instalar el micrófono virtual…",
                                   action: micInstalling ? nil : #selector(installVirtualMic), keyEquivalent: "")
                i.target = self
                i.isEnabled = !micInstalling
                i.toolTip = "Baja BlackHole, un micrófono virtual gratuito, y lo instala. Te pide la clave del Mac una vez."
                m.addItem(i)
            }
        }
        if translator != nil || Config.apiKey != nil {
            let c = NSMenuItem(title: "Mostrar subtítulos de la traducción", action: #selector(toggleCaptions), keyEquivalent: "")
            c.target = self
            c.state = Config.showCaptions ? .on : .off
            m.addItem(c)
        }
        for p in processing {
            let i = NSMenuItem(title: p, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        if let d = lastDoc {
            let i = NSMenuItem(title: "Abrir última reunión", action: #selector(openLast), keyEquivalent: "")
            i.target = self
            i.toolTip = d.lastPathComponent
            m.addItem(i)
        }
        m.addItem(.separator())
        let hint = NSMenuItem(title: "Dictar: mantén apretada ⌥ derecha", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.addItem(hint)
        m.addItem(.separator())
        let out = Config.outputFolder()
        m.addItem(withTitle: out.isDrive ? "Abrir carpeta en Google Drive" : "Abrir carpeta de reuniones (local)",
                  action: #selector(openFolder), keyEquivalent: "").target = self
        if !out.isDrive {
            let w = NSMenuItem(title: "Google Drive para escritorio no está instalado", action: nil, keyEquivalent: "")
            w.isEnabled = false
            m.addItem(w)
        }
        let rec = recoverable()
        if !rec.isEmpty {
            m.addItem(withTitle: "Recuperar \(rec.count) grabación(es) interrumpida(s)", action: #selector(recover), keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        let perms = NSMenuItem(title: "Permisos", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        func perm(_ title: String, _ ok: Bool, _ sel: Selector) {
            let i = NSMenuItem(title: (ok ? "✓ " : "✗ ") + title, action: sel, keyEquivalent: "")
            i.target = self
            sub.addItem(i)
        }
        perm("Micrófono", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, #selector(openMicSettings))
        perm("Accesibilidad (para escribir el dictado)", AXIsProcessTrusted(), #selector(openAXSettings))
        perm("Grabación de pantalla y audio del sistema", CGPreflightScreenCaptureAccess(), #selector(openScreenSettings))
        perms.submenu = sub
        m.addItem(perms)
        let engine = Config.isLocal ? "Whisper en este Mac" : "OpenAI"
        let extra = Config.apiKey != nil ? " + resumen" : " (sin resumen)"
        m.addItem(withTitle: "Ajustes… (\(engine)\(extra))", action: #selector(openSetup), keyEquivalent: ",").target = self
        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(withTitle: "Salir de Escriba", action: #selector(quit), keyEquivalent: "q").target = self
    }

    // MARK: Reunión

    @objc private func toggleRecording() {
        if let c = capture { stopRecording(c) } else { startRecording() }
    }

    private func startRecording() {
        if let m = Engine.missing { notify("Escriba", m); setup.show(); return }
        let session = MeetingSession()
        let c = LiveCapture(session: session, externalMic: voice != nil)
        c.onError = { [weak self] m in DispatchQueue.main.async { self?.notify("Grabación", m) } }
        Task { @MainActor in
            do {
                try await c.start()
                self.capture = c
                self.recordStart = Date()
                self.tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshIcon() }
                self.refreshIcon()
            } catch {
                try? FileManager.default.removeItem(at: session.dir)
                self.notify("No pude empezar a grabar", error.localizedDescription)
                if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            }
        }
    }

    private func stopRecording(_ c: LiveCapture) {
        capture = nil
        tick?.invalidate()
        let label = "Procesando reunión de las \(DateFormatter.localizedString(from: recordStart, dateStyle: .none, timeStyle: .short))…"
        processing.append(label)
        refreshIcon()
        busyDirs.insert(c.session.dir.lastPathComponent)
        Task { @MainActor in
            await c.stop()
            let s = c.session
            do {
                let doc = try await s.finalize(audioSources: [s.mic.archiveURL, s.sys.archiveURL])
                self.lastDoc = doc
                self.notify("Reunión lista", doc.deletingPathExtension().lastPathComponent, file: doc)
            } catch {
                log("Falló el cierre de la reunión: \(error)")
                self.notify("No pude terminar la transcripción", "La grabación quedó guardada; usa Recuperar en el menú. \(error.localizedDescription)")
            }
            self.processing.removeAll { $0 == label }
            self.busyDirs.remove(s.dir.lastPathComponent)
            self.refreshIcon()
        }
    }

    // MARK: Traducción en vivo

    /// Volumen del original: cuando la traducción calla y mientras habla.
    static let originalPresets: [(name: String, idle: Double, ducked: Double)] = [
        ("Apagada", 0, 0), ("Muy baja", 0.05, 0.02), ("Baja (recomendada)", 0.10, 0.04), ("Media", 0.20, 0.08),
    ]

    @objc private func setOriginalVolume(_ sender: NSMenuItem) {
        let p = AppDelegate.originalPresets[sender.tag]
        try? Config.update(["volumen_original": p.idle, "volumen_original_con_voz": p.ducked])
        translator?.setOriginalLevels(idle: p.idle, ducked: p.ducked)
    }

    @objc private func toggleTranslate() {
        if let t = translator {
            translator = nil
            captions.hide()
            refreshIcon()
            Task { @MainActor in await t.stop() }
            return
        }
        guard !translatorStarting else { return }
        guard Config.apiKey != nil else { notify("Traducción", "Hace falta la clave de OpenAI. Agrégala en Ajustes."); return }
        translatorStarting = true
        let t = LiveTranslator()
        t.onText = { [weak self] d in self?.captions.append(d) }
        t.onAutoStop = { [weak self] reason in
            guard let self, self.translator === t else { return }
            self.translator = nil
            self.captions.hide()
            self.refreshIcon()
            self.notify("Traducción detenida", reason)
        }
        Task { @MainActor in
            do {
                try await t.start(language: Config.translateTo)
                self.translator = t
                if Config.showCaptions { self.captions.show() }
            } catch {
                self.notify("No pude empezar a traducir", error.localizedDescription)
                if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            }
            self.translatorStarting = false
            self.refreshIcon()
        }
    }

    /// Los dos sentidos a la vez: prende lo que falte o, si ya están los dos, apaga ambos.
    @objc private func toggleInterpreter() {
        if translator != nil && voice != nil {
            toggleTranslate()
            toggleVoice()
            return
        }
        if translator == nil && !translatorStarting { toggleTranslate() }
        if voice == nil && !voiceStarting { toggleVoice() }
    }

    @objc private func toggleVoice() {
        if let v = voice {
            voice = nil
            refreshIcon()
            Task { @MainActor in
                await v.stop()
                self.capture?.useExternalMic(false)
            }
            return
        }
        guard !voiceStarting else { return }
        voiceStarting = true
        let v = VoiceTranslator()
        v.onAutoStop = { [weak self] reason in
            guard let self, self.voice === v else { return }
            self.voice = nil
            self.capture?.useExternalMic(false)
            self.refreshIcon()
            self.notify("Traducción de tu voz detenida", reason)
        }
        v.onWarning = { [weak self] m in self?.notify("Traducción de tu voz", m) }
        v.onMicBuffer = { [weak self] buf, t in self?.capture?.feedMic(buf, hostTime: t) }
        Task { @MainActor in
            do {
                self.capture?.useExternalMic(true)
                try await v.start(language: Config.voiceTo)
                self.voice = v
                self.notify("Te escuchan en inglés", "Hablas por «\(v.micName)». En la llamada deja el micrófono en «ajustes del sistema» o elige \(v.deviceName).")
            } catch {
                self.capture?.useExternalMic(false)
                self.notify("No pude traducir tu voz", error.localizedDescription)
            }
            self.voiceStarting = false
            self.refreshIcon()
        }
    }

    @objc private func installVirtualMic() {
        guard !micInstalling else { return }
        guard capture == nil, translator == nil, voice == nil else {
            notify("Micrófono virtual", "Detén la grabación o la traducción antes de instalarlo: el audio del Mac se corta un par de segundos.")
            return
        }
        micInstalling = true
        notify("Micrófono virtual", "Descargando. En unos segundos el Mac te pide tu clave para instalarlo.")
        Task.detached {
            let r = await VirtualMicInstaller.install()
            await MainActor.run {
                self.micInstalling = false
                switch r {
                case .installed:
                    self.notify("Micrófono virtual instalado", "Ya puedes usar «Traducir mi voz» y el modo intérprete desde el menú de Escriba.")
                case .needsRestart:
                    self.notify("Falta reiniciar el Mac", "El micrófono virtual quedó instalado. Reinicia el Mac y «Traducir mi voz» aparecerá en el menú de Escriba.")
                    let a = NSAlert()
                    a.messageText = "Reinicia el Mac para terminar"
                    a.informativeText = "El micrófono virtual ya quedó instalado. Después de reiniciar, «Traducir mi voz» y el modo intérprete aparecen en el menú de Escriba. No hace falta instalar nada más."
                    a.addButton(withTitle: "Entendido")
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                case .canceled:
                    break
                case .failed(let m):
                    self.notify("No pude instalar el micrófono virtual", "\(m) Te abro la página para instalarlo a mano.")
                    NSWorkspace.shared.open(VirtualMicInstaller.website)
                }
            }
        }
    }

    @objc private func toggleCaptions() {
        let on = !Config.showCaptions
        try? Config.update(["subtitulos": on])
        if translator != nil { if on { captions.show() } else { captions.hide() } }
    }

    private func recoverable() -> [URL] {
        let fm = FileManager.default
        let current = capture?.session.dir.lastPathComponent
        let dirs = (try? fm.contentsOfDirectory(at: Config.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { d in
            d.lastPathComponent != current && !busyDirs.contains(d.lastPathComponent)
                && (fm.fileExists(atPath: d.appendingPathComponent("mic.caf").path) || fm.fileExists(atPath: d.appendingPathComponent("sys.caf").path))
        }
    }

    @objc private func recover() {
        for d in recoverable() {
            let fm = FileManager.default
            var start = Date()
            if let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let s = j["inicio"], let dt = ISO8601DateFormatter().date(from: s) { start = dt }
            // Se mueve a una carpeta aparte para que la sesión nueva no la pise.
            let moved = Config.appSupport.appendingPathComponent("recuperando-\(d.lastPathComponent)")
            try? fm.moveItem(at: d, to: moved)
            let mic2 = moved.appendingPathComponent("mic.caf"), sys2 = moved.appendingPathComponent("sys.caf")
            let label = "Recuperando grabación…"
            processing.append(label)
            refreshIcon()
            Task.detached {
                let session = MeetingSession(startDate: start, archive: false)
                session.feedFiles(mic: fm.fileExists(atPath: mic2.path) ? mic2 : nil, sys: fm.fileExists(atPath: sys2.path) ? sys2 : nil)
                do {
                    let doc = try await session.finalize(audioSources: [mic2, sys2])
                    try? fm.removeItem(at: moved)
                    await MainActor.run { self.lastDoc = doc; self.notify("Reunión recuperada", doc.lastPathComponent, file: doc) }
                } catch {
                    await MainActor.run { self.notify("No pude recuperar la grabación", error.localizedDescription) }
                }
                await MainActor.run { self.processing.removeAll { $0 == label }; self.refreshIcon() }
            }
        }
    }

    // MARK: Acciones

    @objc private func openLast() { if let d = lastDoc { NSWorkspace.shared.open(d) } }
    @objc private func openFolder() { NSWorkspace.shared.open(Config.outputFolder().url) }
    @objc private func openMicSettings() { openPrivacy("Privacy_Microphone") }
    @objc private func openAXSettings() { openPrivacy("Privacy_Accessibility") }
    @objc private func openScreenSettings() { CGRequestScreenCaptureAccess(); openPrivacy("Privacy_ScreenCapture") }
    @objc private func openSetup() { setup.show() }

    /// Sin un menú Editar, Cmd+V no pega en los campos de texto de una app de barra de menú.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { notify("Escriba", "No pude cambiar el inicio automático: \(error.localizedDescription)") }
    }

    // MARK: Avisos

    func notify(_ title: String, _ body: String, file: URL? = nil) {
        log("Aviso: \(title): \(body)")
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let file { c.userInfo = ["path": file.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let p = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
