import AppKit
import AVFoundation
import ApplicationServices

/// Qué teclas se están manteniendo para dictar. Lógica pura, sin audio, para poder probarla sola.
/// ⌥ derecha: dictar. ⌥ derecha + ⇧ derecha (en cualquier orden): dictar y escribir traducido.
struct HoldKeys {
    enum Action: Equatable { case none, start, translateOn, finish, cancel }
    static let rightOption: UInt = 0x40     // NX_DEVICERALTKEYMASK
    static let rightShift: UInt = 0x04      // NX_DEVICERSHIFTKEYMASK
    static let leftShift: UInt = 0x02       // NX_DEVICELSHIFTKEYMASK
    static let control: UInt = 1 << 18
    static let command: UInt = 1 << 20
    private(set) var down = false
    private(set) var translate = false

    /// Cambió una tecla modificadora. `keyCode` 61 es ⌥ derecha y 60 es ⇧ derecha.
    mutating func flagsChanged(keyCode: UInt16, raw: UInt) -> Action {
        let option = raw & HoldKeys.rightOption != 0
        let shift = raw & HoldKeys.rightShift != 0
        if keyCode == 61 {
            if option && !down {
                guard raw & (HoldKeys.command | HoldKeys.control | HoldKeys.leftShift) == 0 else { return .none }
                down = true
                translate = shift
                return .start
            }
            if !option && down {
                down = false
                return .finish
            }
            return .none
        }
        guard down else { return .none }
        if keyCode == 60 {
            // Soltar ⇧ antes que ⌥ no cambia nada: el dictado sigue en modo traducido.
            if shift && !translate { translate = true; return .translateOn }
            return .none
        }
        return .cancel   // apretó otro modificador junto con ⌥
    }

    /// Se apretó una tecla normal: con ⌥ es un símbolo, no un dictado.
    func keyPressed() -> Action { down ? .cancel : .none }
}

/// Mantener apretada la tecla Opción (⌥) derecha: graba. Soltarla: transcribe y escribe el texto donde esté el cursor.
/// Con ⇧ derecha además, el texto se escribe traducido al idioma elegido en el menú.
final class Dictation: NSObject {
    enum State { case idle, listening, transcribing }

    var onState: ((State) -> Void)?
    var onMessage: ((String) -> Void)?
    private var monitors: [Any] = []
    private var recorder: AVAudioRecorder?
    private var holdTimer: Timer?
    private var keys = HoldKeys()
    /// El dictado en curso se va a escribir traducido.
    private(set) var translating = false
    private var canceled = false
    private var startedAt = Date()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("escriba-dictado.m4a")

    func install() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        let action: HoldKeys.Action
        switch e.type {
        case .keyDown: action = keys.keyPressed()
        case .flagsChanged: action = keys.flagsChanged(keyCode: e.keyCode, raw: e.modifierFlags.rawValue)
        default: return
        }
        switch action {
        case .start:
            canceled = false
            translating = keys.translate
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.begin() }
        case .translateOn:
            translating = true
            if recorder != nil { onState?(.listening) }   // para que el ícono muestre el idioma
        case .finish:
            holdTimer?.invalidate()
            if recorder != nil { finish() } else { translating = false }
        case .cancel:
            cancel()
        case .none:
            break
        }
    }

    private func begin() {
        guard keys.down, !canceled, recorder == nil else { return }
        if AudioDevices.realMicUID != nil {
            onMessage?("El dictado no funciona mientras traduces tu voz. Detén la traducción de tu voz y dicta de nuevo.")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            onMessage?("Falta el permiso de micrófono")
            return
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            try? FileManager.default.removeItem(at: url)
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record(forDuration: 300) else { throw EscribaError.other("No pude grabar") }
            recorder = r
            startedAt = Date()
            NSSound(named: "Tink")?.play()
            log("Dictado: escuchando")
            onState?(.listening)
        } catch {
            onMessage?("No pude usar el micrófono: \(error.localizedDescription)")
        }
    }

    private func cancel() {
        canceled = true
        holdTimer?.invalidate()
        if let r = recorder { r.stop(); r.deleteRecording() }
        recorder = nil
        translating = false
        onState?(.idle)
    }

    private func finish() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        let dur = Date().timeIntervalSince(startedAt)
        guard dur >= 0.5 else { translating = false; onState?(.idle); return }
        NSSound(named: "Pop")?.play()
        onState?(.transcribing)
        let file = url
        let target = translating ? Config.dictationLanguage : nil
        Task {
            do {
                let raw = try await Engine.transcribe(file: file, prompt: Engine.vocabularyPrompt)
                var text = TextClean.forDictation(raw)
                log("Dictado: \(String(format: "%.1f", dur)) s de audio, \(text.count) caracteres, accesibilidad=\(AXIsProcessTrusted())")
                var problem: String?
                if let target, !text.isEmpty, !TextClean.isHallucination(text) {
                    // Si la traducción falla, se escribe igual lo dictado en español: nunca se pierde.
                    let t0 = Date()
                    do {
                        text = try await OpenAI.translate(text, to: target)
                        log("Dictado traducido a \(target) en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, \(text.count) caracteres")
                    } catch EscribaError.noKey {
                        problem = "Para dictar traducido hace falta la clave de OpenAI (menú de Escriba > Ajustes). Lo escribí en español."
                    } catch {
                        log("Dictado: no pude traducir: \(error.localizedDescription)")
                        problem = "No pude traducir el dictado, así que lo escribí en español. \(error.localizedDescription)"
                    }
                }
                await MainActor.run {
                    self.translating = false
                    if let problem { self.onMessage?(problem) }
                    if !text.isEmpty && !TextClean.isHallucination(text) { self.insert(text) }
                    else if text.isEmpty, dur >= 3 {
                        self.onMessage?("No escuché nada. Micrófono en uso: «\(AudioDevices.defaultInputName ?? "desconocido")». Si no es el correcto, cámbialo en Ajustes del Sistema > Sonido > Entrada.")
                    }
                    self.onState?(.idle)
                }
            } catch {
                log("Dictado falló: \(error.localizedDescription)")
                await MainActor.run {
                    self.translating = false
                    NSSound.beep()
                    self.onMessage?("No pude transcribir el dictado: \(error.localizedDescription)")
                    self.onState?(.idle)
                }
            }
        }
    }

    /// Pega el texto en la app activa y devuelve el portapapeles como estaba.
    private func insert(_ text: String) {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            onMessage?("Texto copiado. Pégalo con Cmd+V (falta el permiso de Accesibilidad para escribirlo solo)")
            return
        }
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !saved.isEmpty else { return }
            pb.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, d) in pairs { it.setData(d, forType: t) }
                return it
            }
            pb.writeObjects(items)
        }
    }
}
