import AppKit
import RelayKit

/// `@MainActor`-isolated: every method here touches AppKit (status item, menus, `NSAlert`s).
/// Without this, `async` methods like `performToggle()` resume on the cooperative executor (a
/// background thread), and creating an `NSAlert`/`NSWindow` off the main thread makes AppKit throw
/// an uncaught exception → SIGABRT. Main-actor isolation forces all UI work onto the main thread.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private weak var rootMenu: NSMenu?

    private let toggleService = ToggleService()
    private let usageStore = UsageStore()
    private var routingMode: RoutingMode = .claude
    private var proxyStatus: ProxyStatus = .stopped
    private var isBusy = false
    private var lastError: String?
    private var healthTimer: Timer?
    private var logsWindow: ProxyLogsWindowController?
    private var currentSessionUsage: UsageSample = .zero
    private var lifetimeUsage: UsageTotals = UsageTotals()
    private var spendHistory: [Double] = []
    private var currentBalance: Double?

    /// Builds a menu-item title with an emoji prefix on its own font run, separate from the
    /// text run. `NSFont.menuFont` doesn't carry reliable glyph metrics for every emoji (gear/
    /// nut-and-bolt in particular render with a misaligned/duplicated glyph when baked into the
    /// same run as the text) — giving the emoji its own `.appleColorEmoji` run sidesteps that.
    private static func emojiMenuTitle(emoji: String, text: String, color: NSColor) -> NSAttributedString {
        let emojiFont = NSFont(name: "AppleColorEmoji", size: 13) ?? NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(string: emoji, attributes: [.font: emojiFont])
        result.append(NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: color,
        ]))
        return result
    }

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
        lifetimeUsage = usageStore.load()

        // Install the Groq vision callback script so LiteLLM can import it when the proxy runs.
        if let callbackSource = Bundle.main.url(
            forResource: AppSupport.groqVisionCallbackModule,
            withExtension: "py"
        ) {
            try? toggleService.installGroqCallback(from: callbackSource)
        }

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
        commitUsageIfRunning()
        // Revert routing so open sessions don't point at a dead proxy on next launch.
        toggleService.stopProxyManually()
        try? toggleService.revertToClaude()
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
        headerItem.view = RelayHeaderView(
            mode: routingMode,
            proxyStatus: proxyStatus,
            port: toggleService.preferences().proxyPort,
            sessionSpendUSD: currentSessionUsage.spendUSD,
            lifetimeSpendUSD: lifetimeUsage.totalSpendUSD,
            balanceUSD: currentBalance,
            spendHistory: spendHistory
        )
        headerItem.isEnabled = routingMode == .deepSeek
        if routingMode == .deepSeek {
            headerItem.submenu = makeSpendHistoryPopup()
        }
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

        let toggleItem = NSMenuItem()
        if isBusy {
            toggleItem.attributedTitle = Self.emojiMenuTitle(emoji: "⏳", text: "Working…", color: NSColor.secondaryLabelColor)
        } else {
            let targetTitle = routingMode == .deepSeek ? "Switch to Claude" : "Switch to DeepSeek"
            toggleItem.attributedTitle = Self.emojiMenuTitle(emoji: "🔄", text: targetTitle, color: NSColor.labelColor)
        }
        toggleItem.action = #selector(toggleRouting)
        toggleItem.keyEquivalent = ""
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

        let proxyEmoji: String
        let proxyActionTitle: String
        let proxyAction: Selector?
        switch proxyStatus {
        case .running:
            proxyEmoji = "⏹️"
            proxyActionTitle = "Stop Proxy"
            proxyAction = #selector(stopProxy)
        case .starting:
            proxyEmoji = "⏳"
            proxyActionTitle = "Proxy Starting…"
            proxyAction = nil
        default:
            proxyEmoji = "▶️"
            proxyActionTitle = "Start Proxy"
            proxyAction = #selector(startProxy)
        }
        let proxyItem = NSMenuItem()
        proxyItem.attributedTitle = Self.emojiMenuTitle(emoji: proxyEmoji, text: proxyActionTitle, color: NSColor.labelColor)
        proxyItem.action = proxyAction
        proxyItem.keyEquivalent = ""
        proxyItem.target = self
        proxyItem.isEnabled = !isBusy && proxyAction != nil
        menu.addItem(proxyItem)

        let settingsItem = NSMenuItem()
        settingsItem.attributedTitle = Self.emojiMenuTitle(emoji: "🔩", text: "DeepSeek Settings…", color: NSColor.labelColor)
        settingsItem.action = #selector(openSettings)
        settingsItem.keyEquivalent = ""
        settingsItem.target = self
        settingsItem.isEnabled = !isBusy
        menu.addItem(settingsItem)

        let modelItem = NSMenuItem()
        modelItem.attributedTitle = Self.emojiMenuTitle(emoji: "🧠", text: "Model", color: NSColor.labelColor)
        modelItem.submenu = buildModelSubmenu()
        modelItem.isEnabled = !isBusy
        menu.addItem(modelItem)

        let groqSettingsItem = NSMenuItem()
        groqSettingsItem.attributedTitle = Self.emojiMenuTitle(emoji: "🔮", text: "Groq Vision Settings…", color: NSColor.labelColor)
        groqSettingsItem.action = #selector(openGroqSettings)
        groqSettingsItem.keyEquivalent = ""
        groqSettingsItem.target = self
        groqSettingsItem.isEnabled = !isBusy
        menu.addItem(groqSettingsItem)

        let clipboardItem = NSMenuItem()
        clipboardItem.attributedTitle = Self.emojiMenuTitle(emoji: "👁️", text: "Describe Clipboard", color: NSColor.labelColor)
        clipboardItem.action = #selector(describeClipboard)
        clipboardItem.keyEquivalent = ""
        clipboardItem.target = self
        clipboardItem.isEnabled = !isBusy
        menu.addItem(clipboardItem)

        let logsItem = NSMenuItem()
        logsItem.attributedTitle = Self.emojiMenuTitle(emoji: "📋", text: "View Proxy Logs", color: NSColor.labelColor)
        logsItem.action = #selector(openLogs)
        logsItem.keyEquivalent = ""
        logsItem.target = self
        menu.addItem(logsItem)

        let repairItem = NSMenuItem()
        repairItem.attributedTitle = Self.emojiMenuTitle(emoji: "🔧", text: "Repair / Reinstall LiteLLM Environment", color: NSColor.labelColor)
        repairItem.action = #selector(repairEnvironment)
        repairItem.keyEquivalent = ""
        repairItem.target = self
        repairItem.isEnabled = !isBusy
        menu.addItem(repairItem)

        menu.addItem(.separator())

        // Always available, regardless of what routingMode/proxyStatus currently think —
        // this is the in-app break-glass button for when persisted state and the real
        // settings files disagree (e.g. after a crash left them out of sync).
        let forceRevertItem = NSMenuItem()
        forceRevertItem.attributedTitle = Self.emojiMenuTitle(
            emoji: "🆘",
            text: "Force Revert to Claude",
            color: NSColor.systemRed
        )
        forceRevertItem.action = #selector(forceRevertToClaude)
        forceRevertItem.keyEquivalent = ""
        forceRevertItem.target = self
        forceRevertItem.isEnabled = !isBusy
        menu.addItem(forceRevertItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "🚪 Quit Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeSpendHistoryPopup() -> NSMenu {
        let submenu = NSMenu()
        let item = NSMenuItem()
        item.view = SpendHistoryView(samples: spendHistory)
        submenu.addItem(item)
        return submenu
    }

    private func buildModelSubmenu() -> NSMenu {
        let prefs = toggleService.preferences()
        let submenu = NSMenu()
        for option in prefs.deepSeekModelOptions {
            let item = NSMenuItem()
            item.title = Self.shortModelLabel(option)
            item.state = (option == prefs.deepSeekModelString) ? .on : .off
            item.action = #selector(selectModel(_:))
            item.keyEquivalent = ""
            item.target = self
            item.representedObject = option
            item.isEnabled = !isBusy
            submenu.addItem(item)
        }
        return submenu
    }

    /// "deepseek/deepseek-v4-flash" -> "V4 Flash"
    private static func shortModelLabel(_ model: String) -> String {
        let suffix = model.split(separator: "/").last.map(String.init) ?? model
        return suffix
            .replacingOccurrences(of: "deepseek-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol = routingMode == .deepSeek
            ? "arrow.triangle.2.circlepath.circle.fill"
            : "arrow.triangle.2.circlepath"
        let accentColor: NSColor = routingMode == .deepSeek
            ? NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.94, alpha: 1)
            : NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.31, alpha: 1)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relay")
        let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
        button.image = image?.withSymbolConfiguration(config)
        button.image?.isTemplate = false
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
                commitUsageIfRunning()
                result = try await toggleService.switchToClaude()
                spendHistory.removeAll()
                currentBalance = nil
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
        commitUsageIfRunning()
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
                modelString: prefs.deepSeekModelString,
                modelOptions: prefs.deepSeekModelOptions,
                port: prefs.proxyPort
            ) { [weak self] apiKey, modelString, port in
                guard let self else { return }
                if let apiKey {
                    self.toggleService.setDeepSeekAPIKey(apiKey)
                }
                Task { await self.performUpdateDeepSeekSettings(model: modelString, port: port) }
            }
        }
    }

    private func performUpdateDeepSeekSettings(model: String, port: Int) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await toggleService.updateDeepSeekSettings(model: model, port: port)
            proxyStatus = toggleService.proxy.status
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performSelectModel(model) }
        }
    }

    private func performSelectModel(_ model: String) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await toggleService.setDeepSeekModel(model)
            proxyStatus = toggleService.proxy.status
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    @objc private func openGroqSettings() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prefs = self.toggleService.preferences()
            GroqSettingsPanel.present(
                currentKeyPresent: self.toggleService.hasGroqAPIKey(),
                modelString: prefs.groqModelString
            ) { [weak self] apiKey, modelString in
                guard let self else { return }
                if let apiKey {
                    self.toggleService.setGroqAPIKey(apiKey)
                }
                var updated = prefs
                updated.groqModelString = modelString
                try? self.toggleService.savePreferences(updated)
            }
        }
    }

    @objc private func describeClipboard() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performDescribeClipboard() }
        }
    }

    private func performDescribeClipboard() async {
        guard let imageData = ClipboardImageReader.readFromClipboard() else {
            showError("No image found on the clipboard.")
            return
        }
        guard let apiKey = toggleService.getGroqAPIKey(), !apiKey.isEmpty else {
            showError("Set your Groq API key first (Groq Vision Settings…).")
            return
        }

        let client = GroqVisionClient(apiKey: apiKey, model: toggleService.groqModelString())
        do {
            let description = try await client.describe(imageData: imageData, promptKey: "analyze")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(description, forType: .string)
            showClipboardResult(description)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showClipboardResult(_ description: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Clipboard Described (copied to clipboard)"
        alert.informativeText = description
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    @objc private func forceRevertToClaude() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performForceRevert() }
        }
    }

    private func performForceRevert() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        commitUsageIfRunning()
        do {
            try toggleService.revertToClaude()
            routingMode = .claude
            proxyStatus = toggleService.proxy.status
            spendHistory.removeAll()
            currentBalance = nil
            refreshStatusItem()
            showInfo("Reverted to Claude. Restart any open `claude` terminal sessions or VS Code windows to pick up the change.")
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
        let port = toggleService.preferences().proxyPort
        let healthy = await ProxyHealthChecker().check(port: port)
        if !healthy {
            proxyStatus = .failed("health check failed")
            refreshStatusItem()
            return
        }
        proxyStatus = .running
        let scraper = UsageScraper(baseURL: AppSupport.baseURL(port: port))
        if let sample = try? await scraper.scrape() {
            currentSessionUsage = sample
            spendHistory.append(sample.spendUSD)
            let max = 60 // 30 min at 30s
            if spendHistory.count > max { spendHistory.removeFirst(spendHistory.count - max) }
        }
        // Balance is independent of proxy health — fetch it when proxy is running.
        if let apiKey = toggleService.deepSeekAPIKey() {
            currentBalance = try? await BalanceFetcher().fetch(apiKey: apiKey)
        }
    }

    /// Folds the current session's scraped usage into the persisted lifetime totals.
    /// Call right before any action that stops the proxy — its in-memory Prometheus
    /// counters reset to zero on the next start, so this is the only chance to save them.
    private func commitUsageIfRunning() {
        guard case .running = proxyStatus else { return }
        if let updated = try? usageStore.commitSession(currentSessionUsage) {
            lifetimeUsage = updated
        }
        currentSessionUsage = .zero
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
