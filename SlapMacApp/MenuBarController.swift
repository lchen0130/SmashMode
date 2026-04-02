import AppKit
import Combine

// MARK: - Sound profiles

struct SoundProfile {
    let id:          String
    let displayName: String
    let soundNames:  [String]
}

// MARK: -

/// Owns the NSStatusItem (menu bar icon + dropdown menu) and wires the
/// DaemonConnection → AudioManager pipeline together.
final class MenuBarController: NSObject {

    // MARK: - State

    var isEnabled  = true
    var sensitivity: Float = 0.5
    var currentProfileID = "all"   // default: All Sounds

    // MARK: - Dependencies

    private let audio      = AudioManager()
    private let connection = DaemonConnection.shared
    private var bag        = Set<AnyCancellable>()

    // MARK: - UI

    private var statusItem: NSStatusItem?

    // MARK: - Dynamic profiles

    /// Built at call time from whatever sounds AudioManager found in the bundle.
    /// First entry is always "All Sounds"; subsequent entries are one per file.
    private var dynamicProfiles: [SoundProfile] {
        let allNames = audio.loadedSoundNames
        guard !allNames.isEmpty else { return [] }

        var profiles: [SoundProfile] = [
            SoundProfile(id: "all", displayName: "🎵 All Sounds", soundNames: allNames)
        ]
        for name in allNames {
            profiles.append(SoundProfile(id: name, displayName: name, soundNames: [name]))
        }
        return profiles
    }

    // MARK: - Setup

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()

        // React to impacts
        connection.impactPublisher
            .filter { [weak self] _ in self?.isEnabled == true }
            .sink  { [weak self] event in self?.handleImpact(event) }
            .store(in: &bag)

        // React to connection status changes
        connection.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.rebuildMenu()
            }
            .store(in: &bag)

        connection.start()
    }

    // MARK: - Impact handler

    private func handleImpact(_ event: ImpactEvent) {
        // Gate on force magnitude so the sensitivity slider actually does something.
        // sensitivity 0.2 (High)   → minForce 0.0  — fires on any tap
        // sensitivity 0.5 (Medium) → minForce 0.25 — ignores gentle taps
        // sensitivity 0.8 (Low)    → minForce 0.55 — requires a real slap
        let minForce = max(0, (sensitivity - 0.2) / 0.6 * 0.35)
        guard event.magnitude >= minForce else { return }
        audio.play(force: event.magnitude)
        flashIcon()
    }

    // MARK: - Icon

    private func updateIcon() {
        let name = connection.isConnected
            ? "hand.raised.fill"
            : "hand.raised.slash.fill"
        statusItem?.button?.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "SlapMac"
        )
        statusItem?.button?.image?.isTemplate = true
    }

    private func flashIcon() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: "hand.raised.fingers.spread.fill",
            accessibilityDescription: "Slap!"
        )
        statusItem?.button?.image?.isTemplate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.updateIcon()
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        // ── Status line ──────────────────────────────────────────────────
        let statusText = connection.isConnected ? "● Connected to daemon" : "○ Daemon not running"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if !connection.isConnected {
            let hint = NSMenuItem(title: "  sudo ./SlapMacDaemon", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        // ── Enable / disable ─────────────────────────────────────────────
        let toggle = NSMenuItem(
            title: isEnabled ? "Enabled ✓" : "Disabled",
            action: #selector(toggleEnabled),
            keyEquivalent: "e"
        )
        toggle.target = self
        menu.addItem(toggle)

        // ── Sound profile submenu ────────────────────────────────────────
        let profileMenu = NSMenu()
        for profile in dynamicProfiles {
            let item = NSMenuItem(
                title: profile.displayName,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.representedObject = profile.id
            item.state  = (profile.id == currentProfileID) ? .on : .off
            item.target = self
            profileMenu.addItem(item)
        }
        let profileItem = NSMenuItem(title: "Sound Profile", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        // ── Sensitivity submenu ───────────────────────────────────────────
        let sensitivityMenu = NSMenu()
        for (label, value): (String, Float) in [("🤜 Hard slaps only",  0.8),
                                                 ("🖐 Medium",            0.5),
                                                 ("👆 Any tap",           0.2)] {
            let item = NSMenuItem(title: label, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state  = abs(sensitivity - value) < 0.15 ? .on : .off
            item.target = self
            sensitivityMenu.addItem(item)
        }
        let senItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        senItem.submenu = sensitivityMenu
        menu.addItem(senItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit SlapMac",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        self.statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        rebuildMenu()
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Float else { return }
        sensitivity = v
        rebuildMenu()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = dynamicProfiles.first(where: { $0.id == id }) else { return }
        currentProfileID = profile.id
        audio.setProfile(profile.soundNames)
        rebuildMenu()
    }
}
