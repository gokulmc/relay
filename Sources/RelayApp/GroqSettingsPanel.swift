import AppKit
import ObjectiveC
import RelayKit

/// Small AppKit panel for the Groq API key + vision model (matches DeepSeekSettingsPanel style).
enum GroqSettingsPanel {
    static func present(
        currentKeyPresent: Bool,
        modelString: String,
        onSave: @escaping (_ apiKey: String?, _ modelString: String) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Groq Vision Settings"
        alert.informativeText = currentKeyPresent
            ? "Update your Groq API key and vision model. Leave the key blank to keep the existing one."
            : "Enter your Groq API key for clipboard vision and proxy image auto-describe."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 78))

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 44, width: 300, height: 24))
        keyField.placeholderString = currentKeyPresent ? "••••••••  (leave blank to keep)" : "Groq API key"
        container.addSubview(keyField)

        // Accessory/menu-bar apps have no Edit menu, so Cmd+V doesn't reliably route to
        // paste: here — give the field an explicit paste button instead.
        let pasteBtn = NSButton(frame: NSRect(x: 310, y: 44, width: 70, height: 24))
        pasteBtn.title = "Paste"
        pasteBtn.bezelStyle = .inline
        pasteBtn.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(pasteBtn)

        let modelField = NSTextField(frame: NSRect(x: 0, y: 8, width: 380, height: 24))
        modelField.stringValue = modelString
        modelField.placeholderString = AppSupport.defaultGroqModelString
        container.addSubview(modelField)

        alert.accessoryView = container

        let pasteHandler = GroqPasteHandler(keyField: keyField)
        pasteBtn.target = pasteHandler
        pasteBtn.action = #selector(GroqPasteHandler.paste)
        // Keep the handler alive for the modal session by attaching it to the alert.
        objc_setAssociatedObject(alert, &groqPasteHandlerKey, pasteHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(key.isEmpty ? nil : key, model.isEmpty ? AppSupport.defaultGroqModelString : model)
    }
}

private final class GroqPasteHandler: NSObject {
    private weak var keyField: NSSecureTextField?

    init(keyField: NSSecureTextField) {
        self.keyField = keyField
    }

    @objc func paste() {
        guard let field = keyField, let text = NSPasteboard.general.string(forType: .string) else { return }
        field.stringValue = text
    }
}

private var groqPasteHandlerKey: UInt8 = 0
