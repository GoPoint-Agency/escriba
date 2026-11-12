import AppKit

/// Ventana para poner la clave de OpenAI. Si Escriba ya tiene una, Intérprete la usa y esta ventana no hace falta.
final class KeyWindow: NSObject {
    private var window: NSWindow!
    private let keyField = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Guardar", target: nil, action: nil)

    func show() {
        if window == nil { build() }
        keyField.stringValue = Config.settings["openai_api_key"] as? String ?? ""
        status.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String, bold: Bool = false, small: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: small ? 11 : 13)
        if small { l.textColor = .secondaryLabelColor }
        l.preferredMaxLayoutWidth = 432
        return l
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Intérprete"
        window.isReleasedWhenClosed = false
        keyField.placeholderString = "sk-…"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 432
        let title = NSTextField(labelWithString: "Clave de OpenAI")
        title.font = .boldSystemFont(ofSize: 17)
        let stack = NSStackView(views: [
            title,
            label("Intérprete traduce con OpenAI usando tu propia clave. OpenAI cobra cerca de 2 dólares por hora por cada sentido de la traducción.", small: true),
            keyField,
            label("Si ya usas Escriba con una clave, Intérprete la toma sola y no hace falta ponerla aquí.", small: true),
            status, saveButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        keyField.widthAnchor.constraint(equalToConstant: 432).isActive = true
        window.contentView = stack
    }

    @objc private func save() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status.stringValue = "Pega tu clave de OpenAI."; return }
        saveButton.isEnabled = false
        status.stringValue = "Revisando la clave…"
        Task { @MainActor in
            defer { self.saveButton.isEnabled = true }
            if let problem = await OpenAIKey.check(key) { self.status.stringValue = problem; return }
            do {
                try Config.update(["openai_api_key": key, "configurado": true])
                self.window.orderOut(nil)
            } catch {
                self.status.stringValue = "No pude guardar: \(error.localizedDescription)"
            }
        }
    }
}
