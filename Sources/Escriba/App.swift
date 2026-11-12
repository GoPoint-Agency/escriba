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
        // En la prueba automática no se instala el dictado: habría dos Escriba escribiendo a la vez.
        if !CommandLine.arguments.contains("--autotest") { dictation.install() }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        installEditMenu()
        if !Config.configured { setup.show() } else if let m = Engine.missing { notify("Escriba", m) }
        log("Escriba iniciado (micrófono=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized), accesibilidad=\(AXIsProcessTrusted()), pantalla=\(CGPreflightScreenCaptureAccess()))")
        if CommandLine.arguments.contains("--autotest") {
            // Prueba: graba 20 segundos sola y procesa.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startRecording() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 24) { if let c = self.capture { self.stopRecording(c) } }
        }
    }

    func applicationWillTerminate(_ n: Notification) { LocalWhisper.shutdown() }

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
        switch dictState {
        case .listening: symbol = "mic.fill"; tint = .systemRed
        case .transcribing: symbol = "ellipsis.circle"
        case .idle: if capture == nil && !processing.isEmpty { symbol = "doc.text.magnifyingglass" }
        }
        // Dictado traducido: al lado del micrófono se ve a qué idioma va a salir.
        if dictState != .idle, dictation.translating { title = " " + Config.dictationLanguage.uppercased() + title }
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
        if Config.apiKey != nil {
            // Dictas en español y el texto sale en el idioma elegido aquí.
            let current = Config.dictationLanguage
            let name = Config.dictationLanguages.first { $0.code == current }?.name ?? current
            let tr = NSMenuItem(title: "Dictar traducido: ⌥ + ⇧ derechas (\(name))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (k, l) in Config.dictationLanguages.enumerated() {
                let i = NSMenuItem(title: l.name, action: #selector(setDictationLanguage(_:)), keyEquivalent: "")
                i.target = self
                i.tag = k
                i.state = l.code == current ? .on : .off
                sub.addItem(i)
            }
            tr.submenu = sub
            m.addItem(tr)
        } else {
            let tr = NSMenuItem(title: "Dictar traducido: necesita la clave de OpenAI", action: nil, keyEquivalent: "")
            tr.isEnabled = false
            m.addItem(tr)
        }
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
        let c = LiveCapture(session: session)
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

    // MARK: Dictado traducido

    @objc private func setDictationLanguage(_ sender: NSMenuItem) {
        try? Config.update(["dictado_idioma": Config.dictationLanguages[sender.tag].code])
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
