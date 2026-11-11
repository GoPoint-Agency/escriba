import AppKit
import AVFoundation
import ApplicationServices

/// Mantener apretada la tecla Opción (⌥) derecha: graba. Soltarla: transcribe y escribe el texto donde esté el cursor.
final class Dictation: NSObject {
    enum State { case idle, listening, transcribing }

    var onState: ((State) -> Void)?
    var onMessage: ((String) -> Void)?
    private var monitors: [Any] = []
    private var recorder: AVAudioRecorder?
    private var holdTimer: Timer?
    private var keyDown = false
    private var canceled = false
    private var startedAt = Date()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("escriba-dictado.m4a")
    private let rightOptionMask: UInt = 0x40   // NX_DEVICERALTKEYMASK

    func install() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            if keyDown { cancel() }   // ⌥ + otra tecla: estaba escribiendo un símbolo, no dictando
            return
        }
        guard e.type == .flagsChanged else { return }
        let rightOptionDown = (e.modifierFlags.rawValue & rightOptionMask) != 0
        if e.keyCode == 61 {
            if rightOptionDown && !keyDown {
                let others: NSEvent.ModifierFlags = [.command, .control, .shift]
                guard e.modifierFlags.intersection(others).isEmpty else { return }
                keyDown = true
                canceled = false
                holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.begin() }
            } else if !rightOptionDown && keyDown {
                keyDown = false
                holdTimer?.invalidate()
                if recorder != nil { finish() }
            }
        } else if keyDown {
            cancel()   // apretó otro modificador junto con ⌥
        }
    }

    private func begin() {
        guard keyDown, !canceled, recorder == nil else { return }
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
        onState?(.idle)
    }

    private func finish() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        let dur = Date().timeIntervalSince(startedAt)
        guard dur >= 0.5 else { onState?(.idle); return }
        NSSound(named: "Pop")?.play()
        onState?(.transcribing)
        let file = url
        Task {
            do {
                let raw = try await Engine.transcribe(file: file, prompt: Engine.vocabularyPrompt)
                let text = TextClean.forDictation(raw)
                log("Dictado: \(String(format: "%.1f", dur)) s de audio, \(text.count) caracteres, accesibilidad=\(AXIsProcessTrusted())")
                await MainActor.run {
                    if !text.isEmpty && !TextClean.isHallucination(text) { self.insert(text) }
                    else if text.isEmpty, dur >= 3 {
                        self.onMessage?("No escuché nada. Micrófono en uso: «\(AudioDevices.defaultInputName ?? "desconocido")». Si no es el correcto, cámbialo en Ajustes del Sistema > Sonido > Entrada.")
                    }
                    self.onState?(.idle)
                }
            } catch {
                log("Dictado falló: \(error.localizedDescription)")
                await MainActor.run {
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
