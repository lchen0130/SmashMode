import Foundation
import AVFoundation

/// Plays sounds from the active profile whenever an impact is detected.
/// Sound files are discovered dynamically from the app bundle's Sounds directory
/// at startup — drop any .wav or .mp3 into Sounds/ and rebuild; no code changes needed.
final class AudioManager {

    // 3 pooled players per file → up to 3 overlapping plays of the same clip
    private var pools: [String: [AVAudioPlayer]] = [:]
    private var poolIndex = 0

    // The names currently active for playback — set via setProfile()
    private var activeNames: [String] = []

    /// Sorted list of every sound name successfully loaded from the bundle.
    var loadedSoundNames: [String] { pools.keys.sorted() }

    init() {
        // Discover all .wav / .mp3 files inside the bundle's Sounds subdirectory.
        let soundsURL = Bundle.main.resourceURL?.appendingPathComponent("Sounds")
        var discovered: [URL] = []
        if let soundsURL,
           let enumerator = FileManager.default.enumerator(
               at: soundsURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
           ) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "wav" || ext == "mp3" {
                    discovered.append(fileURL)
                }
            }
        }

        // Load each discovered file into a pool of 3 players.
        for fileURL in discovered.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = fileURL.deletingPathExtension().lastPathComponent
            var pool: [AVAudioPlayer] = []
            for _ in 0..<3 {
                if let p = try? AVAudioPlayer(contentsOf: fileURL) {
                    pool.append(p)
                }
            }
            if !pool.isEmpty {
                pools[name] = pool
                print("[AudioManager] Loaded '\(fileURL.lastPathComponent)'")
            } else {
                print("[AudioManager] Could not load '\(fileURL.lastPathComponent)' — skipping.")
            }
        }

        // Default: play all loaded sounds.
        activeNames = loadedSoundNames
        print("[AudioManager] \(pools.count) sound(s) ready: \(activeNames.joined(separator: ", "))")
    }

    // MARK: - Profile switching

    /// Swap the active sound set. Only names with loaded audio are used.
    func setProfile(_ names: [String]) {
        activeNames = names.filter { pools[$0] != nil }
    }

    // MARK: - Playback

    func play(force: Float) {
        let available = activeNames.filter { pools[$0] != nil }
        guard !available.isEmpty else {
            print("[AudioManager] No sounds available in current profile.")
            return
        }

        let name = available[Int.random(in: 0..<available.count)]
        guard let pool = pools[name] else { return }

        let player = pool.first(where: { !$0.isPlaying }) ?? pool[poolIndex % pool.count]
        poolIndex += 1

        player.volume = 0.35 + force * 0.65
        player.currentTime = 0
        player.play()
    }
}
