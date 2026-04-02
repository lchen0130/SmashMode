import Foundation

// ──────────────────────────────────────────────────────────────────────────────
// SlapMacDaemon — must run as root to access IOKit HID accelerometer.
//
// Usage:
//   sudo ./SlapMacDaemon
//
// Streams ImpactEvent JSON lines to any connected clients at /var/run/slapmac.sock
// ──────────────────────────────────────────────────────────────────────────────

guard getuid() == 0 else {
    fputs("SlapMacDaemon must run as root: sudo ./SlapMacDaemon\n", stderr)
    exit(1)
}

print("╔══════════════════════════════╗")
print("║      SlapMac Daemon v1.0     ║")
print("╚══════════════════════════════╝")

let server   = SocketServer()
let detector = ImpactDetector()
let reader   = AccelerometerReader { x, y, z in
    detector.process(x: x, y: y, z: z)
}

detector.onImpact = { force, algorithms in
    let pct = Int(force * 100)
    print("💥 Impact  force=\(pct)%  algorithms=[\(algorithms.joined(separator: ", "))]")
    let event = ImpactEvent(
        timestamp: Date().timeIntervalSince1970,
        magnitude: force,
        algorithms: algorithms
    )
    server.broadcast(event: event)
}

do {
    try server.start()
    try reader.start()
    print("✅ Daemon ready — waiting for slaps...")
    CFRunLoopRun()
} catch {
    fputs("Fatal: \(error)\n", stderr)
    exit(1)
}
