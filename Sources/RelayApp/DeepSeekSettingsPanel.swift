import AppKit
import ObjectiveC
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
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "DeepSeek Settings"
        alert.informativeText = currentKeyPresent
            ? "Update your DeepSeek API key, model, and proxy port. Leave the key blank to keep the existing one."
            : "Enter your DeepSeek API key and choose a model."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 114))

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 80, width: 280, height: 24))
        keyField.placeholderString = currentKeyPresent ? "••••••••  (leave blank to keep)" : "DeepSeek API key"
        container.addSubview(keyField)

        // Accessory/menu-bar apps have no Edit menu, so Cmd+V doesn't reliably route to
        // paste: here — give the field an explicit paste button instead.
        let pasteBtn = NSButton(frame: NSRect(x: 290, y: 80, width: 70, height: 24))
        pasteBtn.title = "Paste"
        pasteBtn.bezelStyle = .inline
        pasteBtn.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(pasteBtn)

        // Include the current value even if it's not one of the standard options, so
        // saving without touching the dropdown never silently discards a custom model.
        var options = modelOptions
        if !options.contains(modelString) {
            options.append(modelString)
        }
        let modelPopup = NSPopUpButton(frame: NSRect(x: 0, y: 44, width: 360, height: 24))
        modelPopup.addItems(withTitles: options)
        modelPopup.selectItem(withTitle: modelString)
        container.addSubview(modelPopup)

        let portLabel = NSTextField(labelWithString: "Proxy Port:")
        portLabel.frame = NSRect(x: 0, y: 11, width: 90, height: 17)
        portLabel.font = NSFont.systemFont(ofSize: 11)
        portLabel.textColor = .secondaryLabelColor
        container.addSubview(portLabel)

        let portField = NSTextField(frame: NSRect(x: 96, y: 8, width: 100, height: 24))
        portField.stringValue = "\(port)"
        portField.placeholderString = "\(AppSupport.defaultPort)"
        container.addSubview(portField)

        alert.accessoryView = container

        let pasteHandler = PasteHandler(keyField: keyField)
        pasteBtn.target = pasteHandler
        pasteBtn.action = #selector(PasteHandler.paste)
        // The button holds an unowned/weak target — keep the handler alive for the
        // duration of the modal session by attaching it to the alert itself.
        objc_setAssociatedObject(alert, &pasteHandlerAssociationKey, pasteHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelPopup.titleOfSelectedItem ?? AppSupport.defaultModelString
        let enteredPort = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let validPort = (enteredPort.map { (1024...65535).contains($0) } ?? false) ? enteredPort! : port
        onSave(key.isEmpty ? nil : key, model, validPort)
    }
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
