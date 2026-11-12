// Dibuja el ícono de Escriba y deja AppIcon.iconset listo para `iconutil`.
// Uso: swift tools/icono.swift <carpeta.iconset>
import AppKit

func dibujar(_ lado: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lado, pixelsHigh: lado, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: lado, height: lado)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(lado) / 1024
    // Base con la forma de los íconos de macOS: 824 de 1024, esquinas redondeadas y sombra suave.
    let base = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let forma = NSBezierPath(roundedRect: base, xRadius: 186 * s, yRadius: 186 * s)
    let sombra = NSShadow()
    sombra.shadowColor = NSColor.black.withAlphaComponent(0.28)
    sombra.shadowBlurRadius = 24 * s
    sombra.shadowOffset = NSSize(width: 0, height: -12 * s)
    NSGraphicsContext.saveGraphicsState()
    sombra.set()
    NSColor(srgbRed: 0.988, green: 0.314, blue: 0, alpha: 1).setFill()
    forma.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 1, green: 0.50, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.96, green: 0.27, blue: 0, alpha: 1))!.draw(in: forma, angle: -90)
    // Onda de voz: siete barras blancas.
    let alturas: [CGFloat] = [0.26, 0.50, 0.82, 0.44, 1.0, 0.60, 0.30]
    let ancho: CGFloat = 58, hueco: CGFloat = 38, maximo: CGFloat = 470
    let total = CGFloat(alturas.count) * ancho + CGFloat(alturas.count - 1) * hueco
    var x = (1024 - total) / 2
    NSColor.white.setFill()
    for h in alturas {
        let alto = max(ancho, maximo * h)
        let r = NSRect(x: x * s, y: (512 - alto / 2) * s, width: ancho * s, height: alto * s)
        NSBezierPath(roundedRect: r, xRadius: ancho / 2 * s, yRadius: ancho / 2 * s).fill()
        x += ancho + hueco
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let salida = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: salida, withIntermediateDirectories: true)
for (nombre, lado) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                       ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try dibujar(lado).write(to: salida.appendingPathComponent("icon_\(nombre).png"))
}
