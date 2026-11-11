import Foundation
import Accelerate

/// Reproduce voz más rápido sin cambiarle el tono (WSOLA). Sirve para que la traducción alcance
/// a quien habla cuando se quedó atrás. Trabaja a 24 kHz, de a 15 ms.
final class TimeCompressor {
    static let frame = 720      // 30 ms
    static let hop = 360        // 15 ms de salida por paso
    static let search = 240     // se busca el mejor empalme en ±10 ms
    private static let window: [Float] = (0..<frame).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frame)) }

    private var buf: [Float] = []
    private var anchor = 0              // inicio, dentro de buf, del último cuadro usado
    private var nominal: Double = 0     // dónde tocaría empezar el próximo cuadro según la velocidad pedida
    private var tail = [Float](repeating: 0, count: hop)
    private var started = false

    /// Muestras de entrada que todavía no salen.
    var backlog: Int { started ? max(0, buf.count - anchor - TimeCompressor.hop) : buf.count }

    func append(_ p: UnsafeBufferPointer<Float>) { buf.append(contentsOf: p) }

    /// Agrega 15 ms a `out`. Devuelve false si todavía falta entrada.
    func step(rate: Double, into out: inout [Float]) -> Bool {
        let F = TimeCompressor.frame, H = TimeCompressor.hop, S = TimeCompressor.search
        if !started {
            guard buf.count >= F else { return false }
            emit(0, &out)
            started = true
            anchor = 0
            nominal = 0
            return true
        }
        let target = nominal + rate * Double(H)
        let n = Int(target.rounded())
        let c = anchor + H                       // por dónde seguiría el audio sin tocarlo
        let locked = n == c
        let lo = locked ? n : max(c - S, n - S, 0)
        let hi = locked ? n : max(lo, n + S)
        guard buf.count >= hi + F, buf.count >= c + H else { return false }
        var best = n
        if !locked {
            buf.withUnsafeBufferPointer { p in
                let base = p.baseAddress!
                var refEnergy: Float = 0
                vDSP_svesq(base + c, 1, &refEnergy, vDSP_Length(H))
                if refEnergy < 1e-5 {
                    best = min(max(c, lo), hi)   // silencio: se sigue derecho
                } else {
                    var bestScore = -Float.greatestFiniteMagnitude
                    for s in lo...hi {
                        var corr: Float = 0, en: Float = 0
                        vDSP_dotpr(base + s, 1, base + c, 1, &corr, vDSP_Length(H))
                        vDSP_svesq(base + s, 1, &en, vDSP_Length(H))
                        let score = corr / (en + 1e-6).squareRoot()
                        if score > bestScore { bestScore = score; best = s }
                    }
                }
            }
        }
        emit(best, &out)
        anchor = best
        // A velocidad normal y ya empalmado, se deja de buscar: menos espera y sin costo.
        nominal = (rate == 1 && best == c) ? Double(best) : target
        if anchor > 8192 {
            buf.removeFirst(anchor)
            nominal -= Double(anchor)
            anchor = 0
        }
        return true
    }

    private func emit(_ start: Int, _ out: inout [Float]) {
        let H = TimeCompressor.hop
        let w = TimeCompressor.window
        for i in 0..<H { out.append(tail[i] + buf[start + i] * w[i]) }
        for i in 0..<H { tail[i] = buf[start + H + i] * w[H + i] }
    }
}

/// Cola de reproducción de la voz traducida. Recibe el audio como llega de OpenAI y lo entrega al parlante
/// con el menor atraso posible. Si la red tropieza y se junta audio, recorta pausas y acelera un poco la voz
/// hasta ponerse al día, en vez de quedarse atrasada el resto de la llamada.
final class Playout {
    struct Stats {
        var underruns = 0               // veces que se quedó sin audio
        var speechUnderruns = 0         // de esas, en plena voz (se oye como un corte)
        var droppedSilence = 0          // muestras de silencio recortadas
        var spedOutput = 0              // muestras reproducidas más rápido de lo normal
        var maxDebt = 0                 // mayor atraso acumulado, en muestras
        var debtSum = 0.0, pulls = 0    // para el promedio
        var pushes = 0
        var received = 0                // muestras recibidas
        var loudOut = 0                 // muestras con voz que salieron
        var cushion = 0                 // colchón vigente, en muestras
        var pulled = 0                  // muestras entregadas al parlante
        var pullCalls = 0
        var lateMax = 0.0               // mayor atraso de una entrega respecto de la más puntual (s)
        var lateOver150 = 0             // entregas que llegaron más de 150 ms tarde
    }

    static let block = 240              // 10 ms
    // El audio llega en trozos de 0,4 s y a destiempo: medido, 1 de cada 7 llega más de 150 ms tarde y los peores
    // casi 400 ms. Un colchón más chico ahorra una décima de segundo pero se oye entrecortado.
    static let minCushion = Int(0.18 * kTR)
    static let maxCushion = Int(0.48 * kTR)
    private let lock = NSLock()
    private var raw: [Float] = []
    private var rawHead = 0
    private let comp = TimeCompressor()
    private var ready: [Float] = []
    private var readyHead = 0
    private var silentRun = 0
    private var debt = 0                // audio de más que hay que sacarse de encima (recortando pausas o acelerando)
    private var curMin = 0, prevMin = 0, bucket = 0   // menor nivel de la cola en la última fracción de segundo
    private var clock = 0               // muestras entregadas al parlante
    private var lastSpeechUnderrun = 0
    private var hold = 0
    private var rebuild = 0             // colchón por recuperar reproduciendo un poco más lento
    private var holdOnResume: Int
    private var dry = true
    private var fade = 0
    private var stats = Stats()
    private var loudInAt: TimeInterval = 0
    private var loudOutAt: TimeInterval = 0
    private var loudOutClock = -1_000_000
    private var firstPush: TimeInterval = 0
    private var earliest = Double.greatestFiniteMagnitude

    /// Colchón contra los saltos de la red. Crece solo si la voz se corta y vuelve a bajar de a poco.
    private(set) var target: Int
    private let adaptive: Bool
    /// Acelerar la voz cuando hay atraso. Si es false, solo se recortan pausas.
    var speedUp: Bool
    /// Tope de aceleración de la voz.
    var maxRate = 1.3

    init(speedUp: Bool, cushion: Double = 0.25, adaptive: Bool = true) {
        self.speedUp = speedUp
        self.adaptive = adaptive
        target = Int(cushion * kTR)
        holdOnResume = target
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var buffered: Int { (raw.count - rawHead) + comp.backlog + (ready.count - readyHead) }

    /// Segundos de audio recibidos que todavía no suenan.
    var backlog: Double { lock.lock(); defer { lock.unlock() }; return Double(buffered) / kTR }
    /// Hace cuánto llegó voz desde OpenAI (segundos).
    var sinceLoudIn: TimeInterval { lock.lock(); defer { lock.unlock() }; return Playout.now - loudInAt }
    /// Hace cuánto salió voz por el parlante (segundos).
    var sinceLoudOut: TimeInterval { lock.lock(); defer { lock.unlock() }; return Playout.now - loudOutAt }
    /// Hay voz traducida sonando o a punto de sonar.
    var speaking: Bool { lock.lock(); defer { lock.unlock() }; let t = Playout.now; return t - loudOutAt < 0.25 || t - loudInAt < 0.25 }
    var snapshot: Stats { lock.lock(); defer { lock.unlock() }; var s = stats; s.cushion = target; s.pulled = clock; return s }

    /// Resumen de cómo trabajó la cola, para el registro.
    static func describe(_ st: Stats) -> String {
        String(format: "Cola: colchón %.0f ms, cortes en plena voz %d, pausas recortadas %.1f s, voz acelerada %.1f s, mayor atraso acumulado %.0f ms. Red: %d entregas, %d llegaron más de 150 ms tarde, la peor %.0f ms",
               Double(st.cushion) / kTR * 1000, st.speechUnderruns, Double(st.droppedSilence) / kTR, Double(st.spedOutput) / kTR, Double(st.maxDebt) / kTR * 1000,
               st.pushes, st.lateOver150, st.lateMax * 1000)
    }

    static func isLoud(_ s: [Float], _ threshold: Float = 0.02) -> Bool {
        var m: Float = 0
        vDSP_maxmgv(s, 1, &m, vDSP_Length(s.count))
        return m > threshold
    }

    /// Audio recién llegado (24 kHz).
    func push(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let loud = Playout.isLoud(samples)
        lock.lock(); defer { lock.unlock() }
        // Puntualidad de la red: cada entrega debería llegar cuando termina de sonar la anterior.
        let t = Playout.now
        if firstPush == 0 { firstPush = t }
        let late = (t - firstPush) - Double(stats.received) / kTR
        earliest = min(earliest, late)
        stats.lateMax = max(stats.lateMax, late - earliest)
        if late - earliest > 0.15 { stats.lateOver150 += 1 }
        stats.pushes += 1
        stats.received += samples.count
        if loud { loudInAt = t }
        if rawHead > 48000 { raw.removeFirst(rawHead); rawHead = 0 }
        raw.append(contentsOf: samples)
    }

    private func rate(for d: Int) -> Double {
        guard speedUp else { return 1 }
        let s = Double(d) / kTR
        if s < 0.10 { return 1 }
        if s < 0.5 { return min(maxRate, 1 + (s - 0.10) / 0.40 * 0.25) }
        if s < 1.5 { return min(maxRate, 1.25 + (s - 0.5) * 0.20) }
        return maxRate
    }

    private func removed(_ n: Int) {
        debt = max(0, debt - n)
        curMin = max(0, curMin - n)
        prevMin = max(0, prevMin - n)
    }

    /// Pasa audio por el acelerador hasta juntar algo listo. Devuelve false si no hay de dónde.
    private func refill() -> Bool {
        if readyHead > 0, readyHead == ready.count { ready.removeAll(keepingCapacity: true); readyHead = 0 }
        while ready.count - readyHead < TimeCompressor.hop {
            let live = min(debt, max(0, buffered - target))
            let r = rebuild > 0 ? 0.85 : rate(for: live)
            if comp.step(rate: r, into: &ready) {
                if r > 1.02 {
                    stats.spedOutput += TimeCompressor.hop
                    removed(Int(Double(TimeCompressor.hop) * (r - 1)))
                } else if r < 1 {
                    rebuild -= Int(Double(TimeCompressor.hop) * (1 - r))
                }
                continue
            }
            // Falta entrada: se le pasa otro bloque de 10 ms, saltando el silencio que sobre.
            let avail = raw.count - rawHead
            guard avail > 0 else { break }
            let n = min(Playout.block, avail)
            var drop = false
            raw.withUnsafeBufferPointer { p in
                var peak: Float = 0
                vDSP_maxmgv(p.baseAddress! + rawHead, 1, &peak, vDSP_Length(n))
                if peak < 0.004 {
                    if silentRun >= 2400, debt >= n, buffered - n >= target { drop = true } else { silentRun += n }
                } else {
                    silentRun = 0
                }
                if !drop { comp.append(UnsafeBufferPointer(rebasing: p[rawHead..<(rawHead + n)])) }
            }
            rawHead += n
            if drop {
                stats.droppedSilence += n
                removed(n)
            }
        }
        return ready.count - readyHead > 0
    }

    /// Lo que debe sonar ahora (24 kHz). Si no hay nada, entrega silencio.
    func pull(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        // Nivel real de la cola: el menor de la última fracción de segundo (justo antes de que llegue más audio).
        let level = buffered
        curMin = min(curMin, level)
        bucket += n
        if bucket >= 12000 { prevMin = curMin; curMin = level; bucket = 0 }
        let floor = min(curMin, prevMin)
        let over = floor - target
        if over > 960 { debt = max(debt, over) } else if over <= 0 { debt = 0 }
        stats.maxDebt = max(stats.maxDebt, debt)
        stats.debtSum += Double(debt)
        stats.pulls += 1
        stats.pullCalls += 1
        if adaptive, target > Playout.minCushion, clock - lastSpeechUnderrun > Int(kTR * 30) {
            target -= 240   // 10 ms menos cada 30 s sin cortes
            lastSpeechUnderrun = clock
        }

        var done = 0
        var peak: Float = 0
        while done < n {
            if hold > 0 {
                let k = min(hold, n - done)
                for i in 0..<k { out[done + i] = 0 }
                hold -= k
                done += k
                continue
            }
            if ready.count - readyHead == 0 {
                guard refill(), ready.count - readyHead > 0 else { break }
                if dry {
                    // Vuelve el audio después de un corte: un respiro corto para no volver a quedarse sin nada.
                    dry = false
                    hold = holdOnResume
                    holdOnResume = 0
                    fade = 120
                    continue
                }
            }
            let k = min(n - done, ready.count - readyHead)
            ready.withUnsafeBufferPointer { p in
                for i in 0..<k {
                    var v = p[readyHead + i]
                    if fade > 0 { v *= Float(120 - fade) / 120; fade -= 1 }
                    out[done + i] = v
                    let a = abs(v)
                    if a > peak { peak = a }
                }
            }
            readyHead += k
            done += k
        }
        if done < n {
            for i in done..<n { out[i] = 0 }
            if !dry {
                dry = true
                stats.underruns += 1
                if clock - loudOutClock < 2400 {
                    // Se cortó en plena voz: hace falta más colchón. Se sigue de inmediato y el colchón se
                    // recupera reproduciendo un poco más lento, sin meter un silencio en medio de la frase.
                    stats.speechUnderruns += 1
                    lastSpeechUnderrun = clock
                    if adaptive { target = min(Playout.maxCushion, target + 1440) }
                    rebuild = target
                    holdOnResume = 0
                } else {
                    holdOnResume = target
                }
            }
        }
        clock += n
        if peak > 0.02 {
            loudOutAt = Playout.now
            loudOutClock = clock
            stats.loudOut += n
        }
    }
}
