import AppKit
import RelayKit

final class ProxyLogsWindowController: NSWindowController {
    private let textView: NSTextView
    private let logStore: ProxyLogStore
    private var timer: Timer?

    init(logStore: ProxyLogStore) {
        self.logStore = logStore

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        self.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Relay — Proxy Logs"
        window.contentView = scroll
        window.center()

        super.init(window: window)
        refresh()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        let text = logStore.joinedText
        if textView.string != text {
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
    }
}
