import AppKit
import RelayKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private weak var rootMenu: NSMenu?

    private let toggleService = ToggleService()
    private var routingMode: RoutingMode = .claude
    private var proxyStatus: ProxyStatus = .stopped
    private var isBusy = false
    private var lastError: String?
    private var healthTimer: Timer?
    private var logsWindow: ProxyLogsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Relay"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        routingMode = toggleService.currentMode()

        Task { [weak self] in
            guard let self else { return }
            let status = await self.toggleService.proxy.reconcileAtStartup()
            await MainActor.run {
                self.proxyStatus = status
                self.refreshStatusItem()
                // If we were routed to DeepSeek but proxy is down, surface that — don't auto-start.
                if self.routingMode == .deepSeek, status == .stopped {
                    self.lastError = "Proxy stopped — click Start Proxy or Switch to DeepSeek again."
                }
            }
        }

        let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.refreshProxyHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer

        refreshStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        toggleService.stopProxyManually()
    }

    func menuWillOpen(_ menu: NSMenu) {
        proxyStatus = toggleService.proxy.status
        routingMode = toggleService.currentMode()
        rebuildMenu(menu)
    }

    // MARK: - Menu

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        rootMenu = menu

        let headerItem = NSMenuItem()
        headerItem.view = RelayHeaderView(mode: routingMode, proxyStatus: proxyStatus)
        headerItem.isEnabled = false
        headerItem.setAccessibilityLabel(RelayHeaderView.accessibilityLabel(mode: routingMode, proxyStatus: proxyStatus))
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if let lastError, !lastError.isEmpty {
            let errorItem = NSMenuItem()
            errorItem.attributedTitle = NSAttributedString(string: "⚠️ \(lastError)", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.systemRed,
            ])
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        let toggleTitle = routingMode == .deepSeek ? "Switch to Claude" : "Switch to DeepSeek"
        let toggleItem = NSMenuItem(
            title: isBusy ? "Working…" : toggleTitle,
            action: #selector(toggleRouting),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = !isBusy
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let sectionItem = NSMenuItem()
        sectionItem.attributedTitle = NSAttributedString(string: "ACTIONS", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.5,
        ])
        sectionItem.isEnabled = false
        menu.addItem(sectionItem)

        let proxyActionTitle: String
        let proxyAction: Selector?
        switch proxyStatus {
        case .running:
            proxyActionTitle = "Stop Proxy"
            proxyAction = #selector(stopProxy)
        case .starting:
            proxyActionTitle = "Proxy Starting…"
            proxyAction = nil
        default:
            proxyActionTitle = "Start Proxy"
            proxyAction = #selector(startProxy)
        }
        let proxyItem = NSMenuItem(title: proxyActionTitle, action: proxyAction, keyEquivalent: "")
        proxyItem.target = self
        proxyItem.isEnabled = !isBusy && proxyAction != nil
        menu.addItem(proxyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "DeepSeek Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.isEnabled = !isBusy
        menu.addItem(settingsItem)

        let logsItem = NSMenuItem(
            title: "View Proxy Logs",
            action: #selector(openLogs),
            keyEquivalent: ""
        )
        logsItem.target = self
        menu.addItem(logsItem)

        let repairItem = NSMenuItem(
            title: "Repair / Reinstall LiteLLM Environment",
            action: #selector(repairEnvironment),
            keyEquivalent: ""
        )
        repairItem.target = self
        repairItem.isEnabled = !isBusy
        menu.addItem(repairItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol = routingMode == .deepSeek
            ? "arrow.triangle.2.circlepath.circle.fill"
            : "arrow.triangle.2.circlepath"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relay")
        button.image?.isTemplate = true
        button.toolTip = routingMode == .deepSeek
            ? "Relay: DeepSeek via local proxy"
            : "Relay: Claude (claude.ai)"
    }

    // MARK: - Actions

    @objc private func toggleRouting() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performToggle() }
        }
    }

    private func performToggle() async {
        isBusy = true
        lastError = nil
        defer {
            isBusy = false
            refreshStatusItem()
        }

        do {
            let result: ToggleResult
            if routingMode == .deepSeek {
                result = try await toggleService.switchToClaude()
            } else {
                result = try await toggleService.switchToDeepSeek()
            }
            routingMode = result.mode
            proxyStatus = toggleService.proxy.status
            showCaveat(result.caveatMessage)
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    @objc private func startProxy() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performStartProxy() }
        }
    }

    private func performStartProxy() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await toggleService.startProxyManually()
            proxyStatus = toggleService.proxy.status
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    @objc private func stopProxy() {
        toggleService.stopProxyManually()
        proxyStatus = .stopped
    }

    @objc private func openSettings() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prefs = self.toggleService.preferences()
            DeepSeekSettingsPanel.present(
                currentKeyPresent: self.toggleService.hasDeepSeekAPIKey(),
                modelString: prefs.deepSeekModelString
            ) { [weak self] apiKey, modelString in
                guard let self else { return }
                if let apiKey {
                    self.toggleService.setDeepSeekAPIKey(apiKey)
                }
                var updated = prefs
                updated.deepSeekModelString = modelString
                try? self.toggleService.savePreferences(updated)
            }
        }
    }

    @objc private func openLogs() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.logsWindow == nil {
                self.logsWindow = ProxyLogsWindowController(logStore: self.toggleService.logs)
            }
            NSApp.activate(ignoringOtherApps: true)
            self.logsWindow?.showWindow(nil)
            self.logsWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func repairEnvironment() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performRepair() }
        }
    }

    private func performRepair() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await toggleService.repairEnvironment()
            showInfo("LiteLLM environment reinstalled successfully.")
        } catch {
            lastError = error.localizedDescription
            showError(error.localizedDescription)
        }
    }

    private func refreshProxyHealth() async {
        guard case .running = toggleService.proxy.status else {
            proxyStatus = toggleService.proxy.status
            return
        }
        let healthy = await ProxyHealthChecker().check()
        if !healthy {
            proxyStatus = .failed("health check failed")
            refreshStatusItem()
        } else {
            proxyStatus = .running
        }
    }

    private func showCaveat(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Routing updated"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Relay"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showInfo(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Relay"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
