import AppKit
import RelayKit

/// Small AppKit panel for DeepSeek API key + model string (MemBar-style, no SwiftUI).
enum DeepSeekSettingsPanel {
    static func present(
        currentKeyPresent: Bool,
        modelString: String,
        modelOptions: [String],
        port: Int,
        onSave: @escaping (_ apiKey: String?, _ modelString: String, _ port: Int) -> Void
    ) {
        let keyField = NSSecureTextField()
        keyField.placeholderString = currentKeyPresent ? "••••••••  (leave blank to keep)" : "DeepSeek API key"

        // Include the current value even if it's not one of the standard options, so
        // saving without touching the dropdown never silently discards a custom model.
        var options = modelOptions
        if !options.contains(modelString) {
            options.append(modelString)
        }
        let modelPopup = NSPopUpButton()
        modelPopup.addItems(withTitles: options)
        modelPopup.selectItem(withTitle: modelString)

        let portField = NSTextField()
        portField.stringValue = "\(port)"
        portField.placeholderString = "\(AppSupport.defaultPort)"

        let subtitle = currentKeyPresent
            ? "Update your DeepSeek API key, model, and proxy port. Leave the key blank to keep the existing one."
            : "Enter your DeepSeek API key and choose a model."

        let saved = SettingsPanelHelper.run(
            title: "DeepSeek Settings",
            subtitle: subtitle,
            rows: [
                .secureKey(field: keyField),
                .control(label: "Model", view: modelPopup),
                .control(label: "Proxy Port", view: portField),
            ]
        )
        guard saved else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelPopup.titleOfSelectedItem ?? AppSupport.defaultModelString
        let enteredPort = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let validPort = (enteredPort.map { (1024...65535).contains($0) } ?? false) ? enteredPort! : port
        onSave(key.isEmpty ? nil : key, model, validPort)
    }
}
