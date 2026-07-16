import AppKit

/// One row of a settings panel: either a secure API-key field (with an inline Paste
/// button — accessory/menu-bar apps have no Edit menu, so Cmd+V doesn't reliably route
/// to the field), or a plain labeled control (text field, popup, etc).
enum SettingsFieldRow {
    case secureKey(field: NSSecureTextField)
    case control(label: String?, view: NSView)
}

/// Shared AppKit modal-panel builder for Relay's settings dialogs, styled to the MemBar
/// design language. Replaces the old NSAlert + accessoryView approach so both
/// GroqSettingsPanel and DeepSeekSettingsPanel only need to describe their fields —
/// layout, the paste-button wiring, and Enter/Escape handling live here once.
enum SettingsPanelHelper {
    private static let panelWidth: CGFloat = 328
    private static let padding: CGFloat = 18
    private static let rowSpacing: CGFloat = 11

    /// Builds and runs a modal panel. Returns true iff Save was pressed (Cancel, Escape,
    /// or closing the panel all return false).
    @discardableResult
    static func run(title: String, subtitle: String, rows: [SettingsFieldRow]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hide the native titlebar text/chrome — we render our own bold title inside the
        // content so the panel reads as a single flush card, not alert chrome + content.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        let contentWidth = panelWidth - padding * 2

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = contentWidth
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(rowSpacing + 3, after: subtitleLabel)

        var pasteHandlers: [PasteHandler] = []
        var lastRowView: NSView = subtitleLabel

        for row in rows {
            switch row {
            case .secureKey(let field):
                let pasteButton = NSButton(title: "Paste", target: nil, action: nil)
                pasteButton.bezelStyle = .inline
                pasteButton.font = NSFont.systemFont(ofSize: 10)

                let handler = PasteHandler(field: field)
                pasteButton.target = handler
                pasteButton.action = #selector(PasteHandler.paste)
                pasteHandlers.append(handler)

                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
                pasteButton.setContentHuggingPriority(.required, for: .horizontal)

                let rowStack = NSStackView(views: [field, pasteButton])
                rowStack.orientation = .horizontal
                rowStack.spacing = 6
                stack.addArrangedSubview(rowStack)
                rowStack.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
                lastRowView = rowStack

            case .control(let label, let view):
                if let label {
                    let labelField = NSTextField(labelWithString: label)
                    labelField.font = NSFont.systemFont(ofSize: 11)
                    labelField.textColor = .secondaryLabelColor
                    stack.addArrangedSubview(labelField)
                    stack.setCustomSpacing(4, after: labelField)
                }
                stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
                lastRowView = view
            }
        }

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        // A low-hugging spacer pushes Cancel/Save to the trailing edge of the row.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.setCustomSpacing(rowSpacing + 5, after: lastRowView)
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
        ])
        panel.contentView = contentView
        panel.layoutIfNeeded()
        let fittingHeight = stack.fittingSize.height + padding * 2
        panel.setContentSize(NSSize(width: panelWidth, height: fittingHeight))
        panel.center()

        var saved = false
        let coordinator = PanelCoordinator(
            onSave: { saved = true; NSApp.stopModal() },
            onCancel: { saved = false; NSApp.stopModal() }
        )
        saveButton.target = coordinator
        saveButton.action = #selector(PanelCoordinator.save)
        cancelButton.target = coordinator
        cancelButton.action = #selector(PanelCoordinator.cancel)
        panel.delegate = coordinator

        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        // Local strong refs keep the handlers alive for the (synchronous, blocking)
        // duration of the modal session above.
        _ = pasteHandlers
        _ = coordinator

        return saved
    }
}

private final class PasteHandler: NSObject {
    private weak var field: NSSecureTextField?

    init(field: NSSecureTextField) {
        self.field = field
    }

    @objc func paste() {
        guard let field, let text = NSPasteboard.general.string(forType: .string) else { return }
        field.stringValue = text
    }
}

/// Wires up Save/Cancel button actions and treats closing the panel (traffic-light
/// button, Cmd+W) the same as Cancel.
private final class PanelCoordinator: NSObject, NSWindowDelegate {
    private let onSave: () -> Void
    private let onCancel: () -> Void

    init(onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
    }

    @objc func save() { onSave() }
    @objc func cancel() { onCancel() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCancel()
        return true
    }
}
