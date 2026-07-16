import AppKit
import RelayKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private weak var rootMenu: NSMenu?

    private let toggleService = ToggleService()
    private let usageStore = UsageStore()
    private var routingMode: RoutingMode = .claude
    private var activeProvider: Provider?
    private var proxyStatus: ProxyStatus = .stopped
    private var isBusy = false
    private var lastError: String?
    private var healthTimer: Timer?
    private var logsWindow: ProxyLogsWindowController?
    private var currentSessionUsage: UsageSample = .zero
    private var lifetimeUsage: UsageTotals = UsageTotals()
    private var spendHistory: [Double] = []
    /// DeepSeek account balance — the only provider with a public balance API.
    private var currentBalance: Double?
    /// Keychain reads must never happen during menu tracking: if macOS decides to
    /// show its keychain-access prompt while an NSMenu is open, the menu swallows
    /// every keystroke and the password field can't be typed into. So key presence
    /// and the DeepSeek key are cached here, refreshed only outside menu tracking.
    private var keyPresence: [Provider: Bool] = [:]
    private var cachedDeepSeekKey: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Relay2"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        routingMode = toggleService.currentMode()
        lifetimeUsage = usageStore.load()
        if routingMode == .deepSeek {
            activeProvider = toggleService.preferences().activeProvider
        }
        refreshKeyCache()

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
                if self.routingMode == .deepSeek, status == .stopped {
                    self.lastError = "Proxy stopped \u{2014} click Start Proxy or switch again."
                }
            }
        }

        let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshProxyHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer

        refreshStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        commitUsageIfRunning()
        toggleService.stopProxyManually()
        try? toggleService.revertToClaude()
    }

    func menuWillOpen(_ menu: NSMenu) {
        proxyStatus = toggleService.proxy.status
        routingMode = toggleService.currentMode()
        if routingMode == .deepSeek {
            activeProvider = toggleService.preferences().activeProvider
        }
        rebuildMenu(menu)
        refreshDeepSeekBalance()
    }

    // MARK: - Menu composition

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        rootMenu = menu
        let prefs = toggleService.preferences()

        // Header — hovering it opens the spend-history popup.
        let headerItem = NSMenuItem()
        headerItem.view = RelayHeaderView(
            mode: routingMode,
            provider: activeProvider,
            proxyStatus: proxyStatus,
            port: prefs.proxyPort,
            sessionSpendUSD: currentSessionUsage.spendUSD,
            lifetimeSpendUSD: lifetimeUsage.totalSpendUSD,
            balanceUSD: currentBalance,
            spendHistory: spendHistory
        )
        headerItem.isEnabled = routingMode == .deepSeek
        if routingMode == .deepSeek {
            let popup = NSMenu()
            let chartItem = NSMenuItem()
            chartItem.view = SpendHistoryView(samples: spendHistory)
            popup.addItem(chartItem)
            headerItem.submenu = popup
        }
        headerItem.setAccessibilityLabel(
            RelayHeaderView.accessibilityLabel(mode: routingMode, provider: activeProvider, proxyStatus: proxyStatus)
        )
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if let lastError, !lastError.isEmpty {
            let errorItem = NSMenuItem()
            errorItem.attributedTitle = styledText("\u{26A0}\u{FE0F} \(lastError)", size: 12, color: .systemRed)
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        // ROUTING — unified target list.
        menu.addItem(sectionLabel("ROUTING"))
        menu.addItem(makeClaudeRow(prefs: prefs))
        for provider in Provider.allCases {
            menu.addItem(makeProviderRow(provider, prefs: prefs))
        }
        menu.addItem(.separator())

        // ACTIONS
        menu.addItem(sectionLabel("ACTIONS"))

        let proxyItem = NSMenuItem()
        switch proxyStatus {
        case .running:
            proxyItem.title = "Stop Proxy"
            proxyItem.action = #selector(stopProxy)
        case .starting:
            proxyItem.title = "Proxy Starting\u{2026}"
            proxyItem.action = nil
        default:
            proxyItem.title = "Start Proxy"
            proxyItem.action = #selector(startProxy)
        }
        proxyItem.target = self
        proxyItem.isEnabled = !isBusy && proxyItem.action != nil
        menu.addItem(proxyItem)

        let portItem = NSMenuItem()
        portItem.attributedTitle = styledInline(
            primary: "Port\u{2026}",
            primaryWeight: .regular,
            secondary: "\(prefs.proxyPort)",
            secondaryColor: .tertiaryLabelColor
        )
        portItem.action = #selector(openPortSettings)
        portItem.target = self
        portItem.isEnabled = !isBusy
        menu.addItem(portItem)

        let logsItem = NSMenuItem(title: "View Proxy Logs", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        let repairItem = NSMenuItem(title: "Repair LiteLLM Environment", action: #selector(repairEnvironment), keyEquivalent: "")
        repairItem.target = self
        repairItem.isEnabled = !isBusy
        menu.addItem(repairItem)

        let groqSettingsItem = NSMenuItem(title: "Groq Vision Settings", action: #selector(openGroqSettings), keyEquivalent: "")
        groqSettingsItem.target = self
        groqSettingsItem.isEnabled = !isBusy
        menu.addItem(groqSettingsItem)

        let clipboardItem = NSMenuItem(title: "Describe Clipboard", action: #selector(describeClipboard), keyEquivalent: "")
        clipboardItem.target = self
        clipboardItem.isEnabled = !isBusy
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        let forceRevertItem = NSMenuItem()
        forceRevertItem.attributedTitle = styledText("Force Revert to Claude", size: 13, color: .systemRed)
        forceRevertItem.action = #selector(forceRevertToClaude)
        forceRevertItem.target = self
        forceRevertItem.isEnabled = !isBusy
        menu.addItem(forceRevertItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Relay2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func sectionLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = styledText(title, size: 10.5, weight: .semibold, color: .tertiaryLabelColor, kern: 0.5)
        item.isEnabled = false
        return item
    }

    // MARK: - Routing rows

    private static let badgeColors: [Provider: NSColor] = [
        .deepSeek: NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.94, alpha: 1),
        .anthropic: NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        .openAI: NSColor(calibratedRed: 0.10, green: 0.65, blue: 0.55, alpha: 1),
        .gemini: NSColor(calibratedRed: 0.45, green: 0.42, blue: 0.90, alpha: 1),
    ]
    private static let claudeColor = NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.31, alpha: 1)

    private func makeClaudeRow(prefs: RelayPreferences) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = RoutingRowView(
            model: RoutingRowView.Model(
                name: "Claude",
                subline: "claude.ai direct",
                rightText: nil,
                rightTextDimmed: false,
                badgeInitial: "C",
                badgeColor: Self.claudeColor,
                isActive: routingMode == .claude,
                hasSubmenu: false
            ),
            onSelect: { [weak self] in self?.selectClaude() }
        )
        item.isEnabled = !isBusy
        return item
    }

    private func makeProviderRow(_ provider: Provider, prefs: RelayPreferences) -> NSMenuItem {
        let isActive = routingMode == .deepSeek && activeProvider == provider
        let hasKey = keyPresence[provider] ?? false
        let model = prefs.providerModels[provider] ?? provider.defaultModel

        let rightText: String?
        var dimmed = false
        if !hasKey {
            rightText = "no key"
            dimmed = true
        } else if provider.hasBalance {
            rightText = currentBalance.map(formatUSD) ?? "\u{2014}"
        } else {
            var spent = lifetimeUsage.perProviderSpendUSD[provider] ?? 0
            if isActive { spent += currentSessionUsage.spendUSD }
            rightText = formatUSD(spent)
        }

        let item = NSMenuItem()
        item.view = RoutingRowView(
            model: RoutingRowView.Model(
                name: provider.displayName,
                subline: Provider.shortModelLabel(model),
                rightText: rightText,
                rightTextDimmed: dimmed,
                badgeInitial: String(provider.displayName.prefix(1)),
                badgeColor: Self.badgeColors[provider] ?? .controlAccentColor,
                isActive: isActive,
                hasSubmenu: true
            ),
            onSelect: { [weak self] in self?.selectProvider(provider) }
        )
        item.isEnabled = !isBusy
        item.submenu = makeProviderPopup(provider, prefs: prefs, isActive: isActive, hasKey: hasKey)
        return item
    }

    private func makeProviderPopup(_ provider: Provider, prefs: RelayPreferences, isActive: Bool, hasKey: Bool) -> NSMenu {
        let submenu = NSMenu()

        let usageItem = NSMenuItem()
        usageItem.attributedTitle = styledInline(
            primary: provider.displayName,
            secondary: usageSummary(for: provider, isActive: isActive, hasKey: hasKey)
        )
        usageItem.isEnabled = false
        submenu.addItem(usageItem)
        submenu.addItem(.separator())

        let selectedModel = prefs.providerModels[provider] ?? provider.defaultModel
        let options = prefs.providerModelOptions[provider] ?? provider.modelOptions
        for option in options {
            let modelItem = NSMenuItem()
            modelItem.title = Provider.shortModelLabel(option)
            modelItem.state = option == selectedModel ? .on : .off
            modelItem.action = #selector(selectModel(_:))
            modelItem.target = self
            modelItem.representedObject = ProviderModelChoice(provider: provider, model: option)
            modelItem.isEnabled = !isBusy
            submenu.addItem(modelItem)
        }

        submenu.addItem(.separator())
        let settingsItem = NSMenuItem()
        settingsItem.title = "API Key & Settings\u{2026}"
        settingsItem.action = #selector(openProviderSettings(_:))
        settingsItem.target = self
        settingsItem.representedObject = provider.rawValue
        settingsItem.isEnabled = !isBusy
        submenu.addItem(settingsItem)

        return submenu
    }

    private func usageSummary(for provider: Provider, isActive: Bool, hasKey: Bool) -> String {
        guard hasKey else { return "no API key saved" }
        var parts: [String] = []
        if provider.hasBalance {
            parts.append("Balance \(currentBalance.map(formatUSD) ?? "\u{2014}")")
        }
        var spent = lifetimeUsage.perProviderSpendUSD[provider] ?? 0
        if isActive { spent += currentSessionUsage.spendUSD }
        parts.append("\(formatUSD(spent)) spent")
        if isActive, currentSessionUsage.spendUSD > 0 {
            parts.append("\(formatUSD(currentSessionUsage.spendUSD)) this session")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol = routingMode == .deepSeek
            ? "arrow.triangle.2.circlepath.circle.fill"
            : "arrow.triangle.2.circlepath"
        let accentColor: NSColor = routingMode == .deepSeek
            ? (activeProvider.flatMap { Self.badgeColors[$0] } ?? .controlAccentColor)
            : Self.claudeColor
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relay2")
        let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
        button.image = image?.withSymbolConfiguration(config)
        button.image?.isTemplate = false
        let providerName = activeProvider?.displayName ?? "a provider"
        button.toolTip = routingMode == .deepSeek
            ? "Relay2: \(providerName) via local proxy"
            : "Relay2: Claude (claude.ai)"
    }

    // MARK: - Routing actions

    private func selectClaude() {
        guard routingMode == .deepSeek else { return }
        Task { await performSwitchToClaude() }
    }

    private func selectProvider(_ provider: Provider) {
        if routingMode == .deepSeek, activeProvider == provider { return }
        Task { await performSwitchTo(provider) }
    }

    private func performSwitchToClaude() async {
        isBusy = true
        lastError = nil
        defer {
            isBusy = false
            refreshStatusItem()
        }
        do {
            commitUsageIfRunning()
            let result = try await toggleService.switchToClaude()
            spendHistory.removeAll()
            currentSessionUsage = .zero
            activeProvider = nil
            routingMode = result.mode
            proxyStatus = toggleService.proxy.status
            showInfo("Routing back to Claude. \(ToggleResult.restartCaveat)")
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    private func performSwitchTo(_ provider: Provider) async {
        isBusy = true
        lastError = nil
        defer {
            isBusy = false
            refreshStatusItem()
        }
        do {
            // Proxy restart resets LiteLLM's counters — bank the old provider's spend first.
            commitUsageIfRunning()
            spendHistory.removeAll()
            currentSessionUsage = .zero
            let result = try await toggleService.switchTo(provider: provider)
            routingMode = result.mode
            activeProvider = provider
            proxyStatus = toggleService.proxy.status
            showInfo("Switched to \(provider.displayName). \(ToggleResult.restartCaveat)")
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    // MARK: - Model + settings actions

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ProviderModelChoice else { return }
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performSelectModel(choice.model, for: choice.provider) }
        }
    }

    private func performSelectModel(_ model: String, for provider: Provider) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            let willRestart = routingMode == .deepSeek && activeProvider == provider
            if willRestart {
                commitUsageIfRunning()
                spendHistory.removeAll()
                currentSessionUsage = .zero
            }
            try await toggleService.setModel(model, for: provider)
            proxyStatus = toggleService.proxy.status
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    @objc private func openProviderSettings(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = Provider(rawValue: raw) else { return }
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prefs = self.toggleService.preferences()
            let isActive = self.routingMode == .deepSeek && self.activeProvider == provider
            ProviderSettingsPanel.present(
                provider: provider,
                keyPresent: self.toggleService.hasAPIKey(for: provider),
                modelString: prefs.providerModels[provider] ?? provider.defaultModel,
                modelOptions: prefs.providerModelOptions[provider] ?? provider.modelOptions,
                usageLine: self.usageSummary(
                    for: provider,
                    isActive: isActive,
                    hasKey: self.toggleService.hasAPIKey(for: provider)
                )
            ) { [weak self] apiKey, model in
                guard let self else { return }
                if let apiKey {
                    self.toggleService.setAPIKey(apiKey, for: provider)
                }
                self.refreshKeyCache()
                Task { await self.performSelectModel(model, for: provider) }
            }
        }
    }

    @objc private func openPortSettings() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prefs = self.toggleService.preferences()
            PortSettingsPanel.present(port: prefs.proxyPort) { [weak self] newPort in
                guard let self else { return }
                Task { await self.performUpdatePort(newPort) }
            }
        }
    }

    private func performUpdatePort(_ port: Int) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            commitUsageIfRunning()
            spendHistory.removeAll()
            currentSessionUsage = .zero
            try await toggleService.updatePort(port)
            proxyStatus = toggleService.proxy.status
        } catch {
            lastError = error.localizedDescription
            proxyStatus = toggleService.proxy.status
            showError(error.localizedDescription)
        }
    }

    // MARK: - Groq vision actions

    @objc private func openGroqSettings() {
        rootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prefs = self.toggleService.preferences()
            GroqVisionSettingsPanel.present(
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
            showError("Set your Groq API key first (Groq Vision Settings).")
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

    // MARK: - Proxy actions

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
            let provider = toggleService.preferences().activeProvider
            try await toggleService.startProxyManually(for: provider)
            activeProvider = provider
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
            currentSessionUsage = .zero
            activeProvider = nil
            refreshStatusItem()
            showInfo("Reverted to Claude. Restart any open `claude` terminal sessions or VS Code windows to pick up the change.")
        } catch {
            lastError = error.localizedDescription
            showError(error.localizedDescription)
        }
    }

    // MARK: - Background refresh

    /// Reads every provider's key state once, outside menu tracking, so the
    /// keychain-access prompt (if macOS shows one) appears while typing works.
    private func refreshKeyCache() {
        for provider in Provider.allCases {
            keyPresence[provider] = toggleService.hasAPIKey(for: provider)
        }
        cachedDeepSeekKey = toggleService.apiKey(for: Provider.deepSeek)
    }

    /// Fetches the DeepSeek account balance (independent of the active provider).
    private func refreshDeepSeekBalance() {
        guard let key = cachedDeepSeekKey, !key.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if let balance = try? await BalanceFetcher().fetch(apiKey: key) {
                self.currentBalance = balance
            }
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
            let maxSamples = 60
            if spendHistory.count > maxSamples { spendHistory.removeFirst(spendHistory.count - maxSamples) }
        }
        if let apiKey = cachedDeepSeekKey, !apiKey.isEmpty {
            currentBalance = try? await BalanceFetcher().fetch(apiKey: apiKey)
        }
    }

    private func commitUsageIfRunning() {
        guard case .running = proxyStatus else { return }
        if let updated = try? usageStore.commitSession(currentSessionUsage, provider: activeProvider) {
            lifetimeUsage = updated
        }
        currentSessionUsage = .zero
    }

    // MARK: - Alerts

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Relay2"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showInfo(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Relay2"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Boxed (provider, model) pair for NSMenuItem.representedObject.
private final class ProviderModelChoice: NSObject {
    let provider: Provider
    let model: String
    init(provider: Provider, model: String) {
        self.provider = provider
        self.model = model
    }
}
