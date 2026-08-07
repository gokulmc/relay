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
        storedAPIKey: String?,
        onSave: @escaping (_ apiKey: String?, _ modelString: String, _ refreshedOptions: [String]?) -> Void
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

        // +20 over the original 100 to make room for the status label tucked
        // under the model row, using the same negative-y tuck the popup already used.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))

        let keyLabel = NSTextField(labelWithString: "API key:")
        keyLabel.frame = NSRect(x: 0, y: 93, width: 90, height: 17)
        keyLabel.font = NSFont.systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        container.addSubview(keyLabel)

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 66, width: 280, height: 24))
        keyField.placeholderString = keyPresent
            ? "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}  (leave blank to keep)"
            : "\(provider.displayName) API key"
        container.addSubview(keyField)

        let pasteBtn = NSButton(frame: NSRect(x: 290, y: 66, width: 70, height: 24))
        pasteBtn.title = "Paste"
        pasteBtn.bezelStyle = .inline
        pasteBtn.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(pasteBtn)

        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: 42, width: 60, height: 17)
        modelLabel.font = NSFont.systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        container.addSubview(modelLabel)

        var options = modelOptions
        if !options.contains(modelString) {
            options.append(modelString)
        }
        // Narrower than the key field's row to leave room for the Refresh button,
        // same proportions as the key field / Paste button above.
        let modelPopup = NSPopUpButton(frame: NSRect(x: 0, y: 16, width: 280, height: 24))
        modelPopup.addItems(withTitles: options)
        modelPopup.selectItem(withTitle: modelString)
        container.addSubview(modelPopup)

        let refreshBtn = NSButton(frame: NSRect(x: 290, y: 16, width: 70, height: 24))
        refreshBtn.title = "Refresh"
        refreshBtn.bezelStyle = .inline
        refreshBtn.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(refreshBtn)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 0, y: -4, width: 360, height: 14)
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(statusLabel)

        alert.accessoryView = container

        let pasteHandler = PasteHandler(keyField: keyField)
        pasteBtn.target = pasteHandler
        pasteBtn.action = #selector(PasteHandler.paste)
        objc_setAssociatedObject(alert, &pasteHandlerAssociationKey, pasteHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let refreshHandler = RefreshHandler(
            provider: provider,
            storedAPIKey: storedAPIKey,
            keyField: keyField,
            popup: modelPopup,
            button: refreshBtn,
            statusLabel: statusLabel
        )
        refreshBtn.target = refreshHandler
        refreshBtn.action = #selector(RefreshHandler.refresh)
        objc_setAssociatedObject(alert, &refreshHandlerAssociationKey, refreshHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        alert.window.initialFirstResponder = keyField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelPopup.titleOfSelectedItem ?? provider.defaultModel
        onSave(key.isEmpty ? nil : key, model, refreshHandler.refreshedOptions)
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

/// Fetches the provider's live model catalog and repopulates the popup in place.
/// Owns the fetched list so the panel can hand it back to `onSave` after the modal closes.
private final class RefreshHandler: NSObject {
    private weak var keyField: NSSecureTextField?
    private weak var popup: NSPopUpButton?
    private weak var button: NSButton?
    private weak var statusLabel: NSTextField?
    private let provider: Provider
    private let storedAPIKey: String?
    private let client = ModelCatalogClient()
    private(set) var refreshedOptions: [String]?

    init(
        provider: Provider,
        storedAPIKey: String?,
        keyField: NSSecureTextField,
        popup: NSPopUpButton,
        button: NSButton,
        statusLabel: NSTextField
    ) {
        self.provider = provider
        self.storedAPIKey = storedAPIKey
        self.keyField = keyField
        self.popup = popup
        self.button = button
        self.statusLabel = statusLabel
    }

    @objc func refresh() {
        // Prefer whatever's typed right now (first-time setup: paste key → Refresh →
        // pick model, before Save has ever persisted anything), else fall back to
        // the already-stored key.
        let typed = keyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiKeyToUse = typed.isEmpty ? storedAPIKey : typed
        guard let apiKeyToUse, !apiKeyToUse.isEmpty else {
            statusLabel?.stringValue = "Add an API key first"
            return
        }

        button?.isEnabled = false
        button?.title = "\u{2026}"
        statusLabel?.stringValue = ""

        let provider = self.provider
        let client = self.client
        Task {
            do {
                let models = try await client.fetchModels(for: provider, apiKey: apiKeyToUse)
                await MainActor.run { [weak self] in
                    self?.applyRefreshedOptions(models)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.button?.isEnabled = true
                    self?.button?.title = "Refresh"
                    self?.statusLabel?.stringValue = "Failed \u{2014} \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func applyRefreshedOptions(_ models: [String]) {
        refreshedOptions = models
        let previousSelection = popup?.titleOfSelectedItem
        popup?.removeAllItems()
        popup?.addItems(withTitles: models)
        if let previousSelection, models.contains(previousSelection) {
            popup?.selectItem(withTitle: previousSelection)
        } else {
            popup?.selectItem(at: 0)
        }
        button?.isEnabled = true
        button?.title = "Refresh"
        statusLabel?.stringValue = "Updated \u{2014} \(models.count) models"
    }
}

private var refreshHandlerAssociationKey: UInt8 = 0
