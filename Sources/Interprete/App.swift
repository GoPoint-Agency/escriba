import AppKit
import AVFoundation
import ServiceManagement
import UserNotifications

/// Intérprete: traduce en vivo las llamadas. Lo que te dicen lo escuchas en español y lo que dices sale en inglés.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var translator: LiveTranslator?
    private var translatorStarting = false
    private var voice: VoiceTranslator?
    private var voiceStarting = false
    private var micInstalling = false
    private let captions = CaptionPanel()
    private let ajustes = KeyWindow()
    private var ancla: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        Config.adoptFromEscriba()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        refreshIcon()

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        AudioDevices.restoreMicIfNeeded()
        installEditMenu()
        // Escriba deja fuera de sus grabaciones la voz traducida de Intérprete. Para eso el sistema tiene que ver
        // a Intérprete como una app con ventanas: una ventana invisible de 1 punto lo asegura.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear; w.isOpaque = false; w.alphaValue = 0.01
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.orderFrontRegardless()
        ancla = w
        let auto = CommandLine.arguments.contains { $0.hasPrefix("--autotest-") }
        if Config.apiKey == nil, !auto { ajustes.show() }
        log("Intérprete iniciado (micrófono=\(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized), clave=\(Config.apiKey != nil), micrófono virtual=\(AudioDevices.virtualMic != nil))")
        if CommandLine.arguments.contains("--autotest-voz") {   // prueba: traduce unos segundos de voz (o de ESCRIBA_VOZ_ARCHIVO)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.toggleVoice() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + AppDelegate.testSeconds(17)) {
                if self.voice != nil { self.toggleVoice() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            }
        }
        if CommandLine.arguments.contains("--autotest-interprete") {   // prueba: los dos sentidos
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.toggleInterpreter() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + AppDelegate.testSeconds(22)) {
                log("Prueba: traductor=\(self.translator != nil) voz=\(self.voice != nil)")
                self.toggleInterpreter()
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            }
        }
        if CommandLine.arguments.contains("--autotest-traducir") {   // prueba: traduce lo que suene en el Mac
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.toggleTranslate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + AppDelegate.testSeconds(30)) {
                if self.translator != nil { self.toggleTranslate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        AudioDevices.restoreMicIfNeeded()   // por si se sale con la traducción de voz activa
    }

    /// Duración de las pruebas automáticas (ESCRIBA_PRUEBA_S la cambia).
    static func testSeconds(_ normal: Double) -> Double {
        Double(ProcessInfo.processInfo.environment["ESCRIBA_PRUEBA_S"] ?? "") ?? normal
    }

    // MARK: Ícono

    private func refreshIcon() {
        guard let b = item.button else { return }
        let active = translator != nil || voice != nil
        let img = NSImage(systemSymbolName: active ? "globe" : "bubble.left.and.bubble.right", accessibilityDescription: "Intérprete")
        img?.isTemplate = true
        b.image = img
        b.contentTintColor = active ? .systemOrange : nil
    }

    // MARK: Menú

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
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
            let info = NSMenuItem(title: "Traduciendo: \(reloj(secs)) (cerca de US$ \(cost))", action: nil, keyEquivalent: "")
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
            let info = NSMenuItem(title: "Te escuchan en inglés: \(reloj(secs)) (cerca de US$ \(cost)). Micrófono en la reunión: \(v.deviceName)", action: nil, keyEquivalent: "")
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
        m.addItem(.separator())
        let perms = NSMenuItem(title: "Permisos", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let i1 = NSMenuItem(title: (mic ? "✓ " : "✗ ") + "Micrófono", action: #selector(openMicSettings), keyEquivalent: "")
        i1.target = self
        sub.addItem(i1)
        let i2 = NSMenuItem(title: "Audio del sistema (para escuchar la llamada)…", action: #selector(openAudioSettings), keyEquivalent: "")
        i2.target = self
        sub.addItem(i2)
        perms.submenu = sub
        m.addItem(perms)
        m.addItem(withTitle: Config.apiKey != nil ? "Clave de OpenAI…" : "Poner la clave de OpenAI…", action: #selector(openAjustes), keyEquivalent: ",").target = self
        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(withTitle: "Salir de Intérprete", action: #selector(quit), keyEquivalent: "q").target = self
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
        guard Config.apiKey != nil else { notify("Traducción", "Hace falta la clave de OpenAI."); ajustes.show(); return }
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
            Task { @MainActor in await v.stop() }
            return
        }
        guard !voiceStarting else { return }
        voiceStarting = true
        let v = VoiceTranslator()
        v.onAutoStop = { [weak self] reason in
            guard let self, self.voice === v else { return }
            self.voice = nil
            self.refreshIcon()
            self.notify("Traducción de tu voz detenida", reason)
        }
        v.onWarning = { [weak self] m in self?.notify("Traducción de tu voz", m) }
        Task { @MainActor in
            do {
                try await v.start(language: Config.voiceTo)
                self.voice = v
                self.notify("Te escuchan en inglés", "Hablas por «\(v.micName)». En la llamada deja el micrófono en «ajustes del sistema» o elige \(v.deviceName).")
            } catch {
                self.notify("No pude traducir tu voz", error.localizedDescription)
            }
            self.voiceStarting = false
            self.refreshIcon()
        }
    }

    @objc private func installVirtualMic() {
        guard !micInstalling else { return }
        guard translator == nil, voice == nil else {
            notify("Micrófono virtual", "Detén la traducción antes de instalarlo: el audio del Mac se corta un par de segundos.")
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
                    self.notify("Micrófono virtual instalado", "Ya puedes usar «Traducir mi voz» y el modo intérprete desde el menú de Intérprete.")
                case .needsRestart:
                    self.notify("Falta reiniciar el Mac", "El micrófono virtual quedó instalado. Reinicia el Mac y «Traducir mi voz» aparecerá en el menú de Intérprete.")
                    let a = NSAlert()
                    a.messageText = "Reinicia el Mac para terminar"
                    a.informativeText = "El micrófono virtual ya quedó instalado. Después de reiniciar, «Traducir mi voz» y el modo intérprete aparecen en el menú de Intérprete. No hace falta instalar nada más."
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

    // MARK: Acciones

    @objc private func openMicSettings() { openPrivacy("Privacy_Microphone") }
    @objc private func openAudioSettings() { openPrivacy("Privacy_ScreenCapture") }
    @objc private func openAjustes() { ajustes.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { notify("Intérprete", "No pude cambiar el inicio automático: \(error.localizedDescription)") }
    }

    /// Sin un menú Editar, Cmd+V no pega en los campos de texto de una app de barra de menú.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(NSMenuItem())
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Avisos

    func notify(_ title: String, _ body: String) {
        log("Aviso: \(title): \(body)")
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
