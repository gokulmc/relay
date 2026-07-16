import AppKit
import ObjectiveC
import RelayKit

/// Per-provider settings panel: API key + model for ONE provider only.
/// The provider is fixed at presentation time — no provider dropdown — so the
/// model list can never show another provider's options.
enum ProviderSettingsPanel {
    static func present(
        provider: Provider,
        keyPresent: Bool,
        modelString: String,
        modelOptions: [String],
        usageLine: String,
        onSave: @escaping (_ apiKey: String?, _ modelString: String) -> Void
    ) {
        activateApp()

        let alert = NSAlert()
        alert.messageText = "\(provider.displayName) Settings"
        var info = usageLine
        if !info.isEmpty { info += "\n\n" }
        info += keyPresent
            ? "Update the API key or model. Leave the key blank to keep the existing one."
            : "Enter your \(provider.displayName) API key and choose a model."
        alert.informativeText = info
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
        keyField.placeholderString = keyPresent
            ? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}  (leave blank to keep)"
            : "\(provider.displayName) API key"
        container.addSubview(keyField)

        let pasteBtn = NSButton(frame: NSRect(x: 290, y: 46, width: 70, height: 24))
        pasteBtn.title = "Paste"
        pasteBtn.bezelStyle = .inline
        pasteBtn.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(pasteBtn)

        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: 22, width: 60, height: 17)
        modelLabel.font = NSFont.systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        container.addSubview(modelLabel)

        var options = modelOptions
        if !options.contains(modelString) {
            options.append(modelString)
        }
        let modelPopup = NSPopUpButton(frame: NSRect(x: 0, y: -4, width: 360, height: 24))
        modelPopup.addItems(withTitles: options)
        modelPopup.selectItem(withTitle: modelString)
        container.addSubview(modelPopup)

        alert.accessoryView = container

        let pasteHandler = PasteHandler(keyField: keyField)
        pasteBtn.target = pasteHandler
        pasteBtn.action = #selector(PasteHandler.paste)
        objc_setAssociatedObject(alert, &pasteHandlerAssociationKey, pasteHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        alert.window.initialFirstResponder = keyField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelPopup.titleOfSelectedItem ?? provider.defaultModel
        onSave(key.isEmpty ? nil : key, model)
    }
}

/// Small standalone panel for the proxy port.
enum PortSettingsPanel {
    static func present(port: Int, onSave: @escaping (_ port: Int) -> Void) {
        activateApp()

        let alert = NSAlert()
        alert.messageText = "Proxy Port"
        alert.informativeText = "Local port the LiteLLM proxy listens on (1024\u{2013}65535). Changing it restarts a running proxy."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        portField.stringValue = "\(port)"
        portField.placeholderString = "\(AppSupport.defaultPort)"
        alert.accessoryView = portField
        alert.window.initialFirstResponder = portField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let entered = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let newPort = entered, (1024...65535).contains(newPort), newPort != port else { return }
        onSave(newPort)
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
