import Foundation
import Accelerate

/// Manda a OpenAI el audio que hay que traducir, en trozos de 200 ms, y lleva la cuenta de cuándo hay voz.
///
/// Se probó adelantarle silencio al modelo en las pausas para que respondiera antes (su tiempo avanza con el
/// audio que recibe, no con el reloj). Ganaba 0,3 a 0,8 s por frase, costaba 16 a 29 % más y en 3 de 26 pruebas
/// la traducción salió cortada, repetida o inventada, contra 0 de 20 sin el truco. Por eso no se usa.
final class Feeder {
    private let socket: TranslateSocket
    private var pending: [Float] = []
    private var noise: Float = 0.002
    private(set) var sent = 0                       // muestras enviadas (lo que se cobra)
    private(set) var speechSamples = 0              // de esas, con voz
    private(set) var lastSpeech = Date.distantPast  // última vez que hubo voz en la entrada
    private(set) var lastSend = Date()
    private(set) var peak: Float = 0
    private var started: Date?

    init(socket: TranslateSocket) { self.socket = socket }

    var sentSeconds: Double { Double(sent) / kTR }
    var speechSeconds: Double { Double(speechSamples) / kTR }

    /// Audio real, mono a 24 kHz, tal como se va capturando.
    func ingest(_ s: [Float]) {
        guard !s.isEmpty else { return }
        if started == nil { started = Date() }
        s.withUnsafeBufferPointer { p in
            var i = 0
            while i < s.count {
                let n = min(240, s.count - i)
                var rms: Float = 0, mx: Float = 0
                vDSP_rmsqv(p.baseAddress! + i, 1, &rms, vDSP_Length(n))
                vDSP_maxmgv(p.baseAddress! + i, 1, &mx, vDSP_Length(n))
                peak = max(peak, mx)
                // Piso de ruido: sube de a poco y baja de inmediato. Hay voz si se despega claramente de él.
                noise = min(noise * 1.002 + 0.000001, max(rms, 0.0003))
                if rms > max(0.006, noise * 4) {
                    lastSpeech = Date()
                    speechSamples += n
                }
                i += n
            }
        }
        pending.append(contentsOf: s)
        let n = TranslateSocket.chunk
        while pending.count >= n {
            socket.append(Array(pending[0..<n]))
            pending.removeFirst(n)
            sent += n
            lastSend = Date()
        }
    }

    /// El tiempo del modelo avanza con el audio que recibe: si la captura deja de entregar, se rellena con
    /// silencio hasta alcanzar el reloj. Si no, la traducción que venía en camino llegaría a media velocidad.
    /// Llamar cada 50 a 100 ms.
    func tick() {
        guard let started else { self.started = Date(); return }
        let deficit = Date().timeIntervalSince(started) - Double(sent + pending.count) / kTR
        if deficit > 0.3 {
            ingest([Float](repeating: 0, count: Int((deficit - 0.1) * kTR)))
        }
    }
}

/// Mide el retraso que se percibe: cuánto después de que alguien termina una frase empieza y termina de oírse
/// su traducción. No guarda audio ni texto, solo tiempos.
final class LatencyMeter {
    private var inPhrase = false
    private var awaiting = false
    private var lastIn = Date.distantPast
    private var lastOut = Date.distantPast
    private var phraseEnd = Date.distantPast
    private var onset: Date?
    private var quietAtStart = false
    private(set) var starts: [Double] = []   // la traducción empezó a oírse X s después del fin de la frase (negativo: antes)
    private(set) var ends: [Double] = []     // y terminó de oírse X s después

    /// Llamar cada 50 ms. `lastSpeech`: última voz en la entrada. `sinceLoudOut`: hace cuánto sonó voz traducida.
    func tick(lastSpeech: Date, sinceLoudOut: TimeInterval) {
        let now = Date()
        let inLoud = now.timeIntervalSince(lastSpeech) < 0.15
        let outLoud = sinceLoudOut < 0.15
        if inLoud {
            if awaiting { close(now, contaminated: true) }
            if !inPhrase {
                inPhrase = true
                onset = nil
                quietAtStart = now.timeIntervalSince(lastOut) > 0.5
            }
            lastIn = lastSpeech
        }
        if outLoud {
            if onset == nil, quietAtStart, inPhrase || awaiting { onset = now }
            lastOut = now
        }
        if inPhrase, now.timeIntervalSince(lastIn) >= 0.9 {
            inPhrase = false
            awaiting = true
            phraseEnd = lastIn
        }
        if awaiting {
            let quiet = now.timeIntervalSince(lastOut) >= 0.9
            if quiet && (onset != nil || now.timeIntervalSince(phraseEnd) > 6) || now.timeIntervalSince(phraseEnd) > 15 {
                close(now, contaminated: false)
            }
        }
    }

    private func close(_ now: Date, contaminated: Bool) {
        awaiting = false
        guard let o = onset else { return }
        let s = o.timeIntervalSince(phraseEnd)
        if s > -15, s < 10 { starts.append(s) }
        // Si la otra persona siguió hablando antes de que terminara la traducción, el final no se puede atribuir.
        let e = lastOut.timeIntervalSince(phraseEnd)
        if !contaminated, e > 0, e < 15 { ends.append(e) }
        onset = nil
    }

    private static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    /// Resumen para el registro, o nil si no alcanzó a medir nada.
    var summary: String? {
        guard !starts.isEmpty else { return nil }
        var t = String(format: "en %d frases la traducción empezó a oírse %+.1f s respecto del fin de la frase (mediana)", starts.count, LatencyMeter.median(starts))
        if !ends.isEmpty {
            t += String(format: " y terminó %.1f s después (mediana de %d; peor caso %.1f s)", LatencyMeter.median(ends), ends.count, ends.max() ?? 0)
        }
        return t
    }
}
