import Foundation

/// Broadcasts newline-delimited JSON `ImpactEvent` messages to any connected
/// clients over a Unix domain stream socket.
///
/// The socket is created at `socketPath` with world-readable/writable
/// permissions so the unprivileged app target can connect without needing root.
final class SocketServer {

    static let socketPath = "/var/run/slapmac.sock"

    private var serverFD: Int32 = -1
    private var clients: [Int32] = []
    private let lock = NSLock()

    // MARK: - Lifecycle

    func start() throws {
        // Remove stale socket file
        unlink(Self.socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw SocketError.createFailed(errno) }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                _ = strncpy(cptr, Self.socketPath, 103)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                bind(serverFD, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError.bindFailed(errno) }

        // Allow the unprivileged app to connect
        chmod(Self.socketPath, 0o666)

        guard listen(serverFD, 8) == 0 else { throw SocketError.listenFailed(errno) }

        print("[SocketServer] Listening at \(Self.socketPath)")

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { continue }
            lock.lock()
            clients.append(clientFD)
            lock.unlock()
            print("[SocketServer] Client connected (fd=\(clientFD)). Total: \(clients.count)")
        }
    }

    // MARK: - Broadcast

    func broadcast(event: ImpactEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        let payload = Data((line + "\n").utf8)

        lock.lock()
        let snapshot = clients
        lock.unlock()

        var dead: [Int32] = []
        for fd in snapshot {
            let sent = payload.withUnsafeBytes { buf in
                send(fd, buf.baseAddress!, payload.count, MSG_NOSIGNAL)
            }
            if sent <= 0 { dead.append(fd) }
        }

        if !dead.isEmpty {
            dead.forEach { close($0) }
            lock.lock()
            clients.removeAll { dead.contains($0) }
            lock.unlock()
        }
    }
}

// MARK: - Errors

enum SocketError: Error {
    case createFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}
