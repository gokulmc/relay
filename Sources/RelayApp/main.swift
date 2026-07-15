import AppKit

// Program entry runs on the main thread, but top-level code is treated as nonisolated. The app
// delegate is `@MainActor`-isolated (it drives AppKit), so assert main-actor isolation here to
// construct and install it without hopping executors.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
