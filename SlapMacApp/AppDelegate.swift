import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let menuBar = MenuBarController()

    // Explicit entry point — required when compiling with swiftc directly (build.sh).
    // Xcode ignores this and uses its own generated main; both paths work.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock — we're a pure menu-bar app
        NSApp.setActivationPolicy(.accessory)
        menuBar.setup()
    }
}
