import AppKit
import RelayKit

/// Small AppKit panel for DeepSeek API key + model string (MemBar-style, no SwiftUI).
enum DeepSeekSettingsPanel {
    static func present(
        currentKeyPresent: Bool,
        modelString: String,
        onSave: @escaping (_ apiKey: String?, _ modelString: String) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "DeepSeek Settings"
        alert.informativeText = currentKeyPresent
            ? "Update your DeepSeek API key and model string. Leave the key blank to keep the existing one."
            : "Enter your DeepSeek API key and the LiteLLM model string (e.g. deepseek/deepseek-v4-pro)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 78))

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 44, width: 360, height: 24))
        keyField.placeholderString = currentKeyPresent ? "••••••••  (leave blank to keep)" : "DeepSeek API key"
        container.addSubview(keyField)

        let modelField = NSTextField(frame: NSRect(x: 0, y: 8, width: 360, height: 24))
        modelField.stringValue = modelString
        modelField.placeholderString = "Model string"
        container.addSubview(modelField)

        alert.accessoryView = container

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(key.isEmpty ? nil : key, model.isEmpty ? AppSupport.defaultModelString : model)
    }
}
