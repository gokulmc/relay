import AppKit
import ObjectiveC
import RelayKit

/// Groq Vision settings: API key + vision model string. Mirrors ProviderSettingsPanel's
/// NSAlert + accessoryView style, but Groq isn't a routing `Provider` — it's a global
/// image→text preprocessor in front of whichever provider is active — so this panel is
/// standalone rather than provider-parameterized.
enum GroqVisionSettingsPanel {
    static func present(
        currentKeyPresent: Bool,
        modelString: String,
        onSave: @escaping (_ apiKey: String?, _ modelString: String) -> Void
    ) {
        activateApp()

        let alert = NSAlert()
        alert.messageText = "Groq Vision Settings"
        alert.informativeText = currentKeyPresent
            ? "Update your Groq API key and vision model. Leave the key blank to keep the existing one."
            : "Enter your Groq API key for clipboard vision and proxy image auto-describe."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))

        let keyLabel = NSTextField(labelWithString: "API key:")
        keyLabel.frame = NSRect(x: 0, y: 73, width: 90, height: 17)
        keyLabel.font = NSFont.systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        container.addSubview(keyLabel)

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 46, width: 280, height: 24))
        keyField.placeholderString = currentKeyPresent
            ? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}  (leave blank to keep)"
            : "Groq API key"
        container.addSubview(keyField)

        let pasteBtn = NSButton(frame: NSRect(x: 290, y: 46, width: 70, height: 24))
        pasteBtn.title = "Paste"
        pasteBtn.bezelStyle = .inline
        pasteBtn.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(pasteBtn)

        let modelLabel = NSTextField(labelWithString: "Vision model:")
        modelLabel.frame = NSRect(x: 0, y: 22, width: 100, height: 17)
        modelLabel.font = NSFont.systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        container.addSubview(modelLabel)

        let modelField = NSTextField(frame: NSRect(x: 0, y: -4, width: 360, height: 24))
        modelField.stringValue = modelString
        modelField.placeholderString = AppSupport.defaultGroqModelString
        container.addSubview(modelField)

        alert.accessoryView = container

        let pasteHandler = PasteHandler(keyField: keyField)
        pasteBtn.target = pasteHandler
        pasteBtn.action = #selector(PasteHandler.paste)
        objc_setAssociatedObject(alert, &pasteHandlerAssociationKey, pasteHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        alert.window.initialFirstResponder = keyField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(key.isEmpty ? nil : key, model.isEmpty ? AppSupport.defaultGroqModelString : model)
    }
}

/// Accessory-policy apps don't reliably become active on macOS 14+; without
/// activation the alert never becomes key and typing goes nowhere.
private func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
}

private final class PasteHandler: NSObject {
    private weak var keyField: NSSecureTextField?

    init(keyField: NSSecureTextField) {
        self.keyField = keyField
    }

    @objc func paste() {
        guard let field = keyField, let text = NSPasteboard.general.string(forType: .string) else { return }
        field.stringValue = text
    }
}

private var pasteHandlerAssociationKey: UInt8 = 0
