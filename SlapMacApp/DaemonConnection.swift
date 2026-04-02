import Foundation
import Combine

/// Connects to the SlapMacDaemon over a Unix domain socket and publishes
/// decoded `ImpactEvent` values.  Automatically reconnects every 2 s if the
/// daemon is not yet running or the connection drops.
final class DaemonConnection: ObservableObject {

    static let shared = DaemonConnection()

    // Downstream subscribers (AudioManager, MenuBarController) listen here
    let impactPublisher = PassthroughSubject<ImpactEvent, Never>()

    @Published private(set) var isConnected = false

    private var socketFD: Int32 = -1
    private let socketPath = "/var/run/slapmac.sock"

    // MARK: - Lifecycle

    func start() {
        attemptConnect()
    }

    // MARK: - Connection management

    private func attemptConnect() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleReconnect(); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                _ = strncpy(cptr, socketPath, 103)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                connect(fd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result == 0 {
            socketFD = fd
            DispatchQueue.main.async { self.isConnected = true }
            Thread.detachNewThread { [weak self] in self?.readLoop(fd: fd) }
        } else {
            close(fd)
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.attemptConnect()
        }
    }

    // MARK: - Read loop

    private func readLoop(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        var pending = ""

        while true {
            let n = recv(fd, &buf, buf.count - 1, 0)
            if n <= 0 {
                close(fd)
                DispatchQueue.main.async { self.isConnected = false }
                scheduleReconnect()
                return
            }

            pending += String(bytes: buf[0..<n], encoding: .utf8) ?? ""

            // Consume complete newline-delimited JSON lines
            while let range = pending.range(of: "\n") {
                let line = String(pending[..<range.lowerBound])
                pending = String(pending[range.upperBound...])

                if let data  = line.data(using: .utf8),
                   let event = try? JSONDecoder().decode(ImpactEvent.self, from: data) {
                    DispatchQueue.main.async {
                        self.impactPublisher.send(event)
                    }
                }
            }
        }
    }
}
