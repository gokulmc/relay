import AppKit
import RelayKit

/// Small AppKit panel for the Groq API key + vision model (matches DeepSeekSettingsPanel style).
enum GroqSettingsPanel {
    static func present(
        currentKeyPresent: Bool,
        modelString: String,
        onSave: @escaping (_ apiKey: String?, _ modelString: String) -> Void
    ) {
        let keyField = NSSecureTextField()
        keyField.placeholderString = currentKeyPresent ? "••••••••  (leave blank to keep)" : "Groq API key"

        let modelField = NSTextField()
        modelField.stringValue = modelString
        modelField.placeholderString = AppSupport.defaultGroqModelString

        let subtitle = currentKeyPresent
            ? "Update your Groq API key and vision model. Leave the key blank to keep the existing one."
            : "Enter your Groq API key for clipboard vision and proxy image auto-describe."

        let saved = SettingsPanelHelper.run(
            title: "Groq Vision Settings",
            subtitle: subtitle,
            rows: [
                .secureKey(field: keyField),
                .control(label: "Vision Model", view: modelField),
            ]
        )
        guard saved else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(key.isEmpty ? nil : key, model.isEmpty ? AppSupport.defaultGroqModelString : model)
    }
}
