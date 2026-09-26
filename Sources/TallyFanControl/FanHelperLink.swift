import Foundation

/// What the helper reports for one fan.
struct HelperFan: Equatable {
    var id: Int
    var rpm: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var isManual: Bool
    var isForcedByHelper: Bool
}

struct HelperStatus: Equatable {
    var version: Int
    var isDryRun: Bool
    var fans: [HelperFan]

    var hasForcedFans: Bool { fans.contains(where: \.isForcedByHelper) }
}

enum HelperFailure: Error, Equatable {
    /// Nothing is listening: the helper is not loaded.
    case unreachable
    /// The helper answered with an error, such as a user it does not accept.
    case refused(String)
    /// The connection dropped or the reply made no sense.
    case broken
}

/// The socket to the fan helper. Requests run one at a time on a private queue. The connection stays open only
/// while the helper has fans forced, so the helper can put them back to automatic if Tally goes away.
final class FanHelperLink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tally.fans.helper", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var watcher: DispatchSourceRead?

    /// Called on the main queue when a held connection closes on the helper's side.
    var onConnectionLost: (() -> Void)?

    func send(_ request: [String: Any], completion: @escaping (Result<HelperStatus, HelperFailure>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = exchange(request, timeout: 4)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Returns every fan to automatic and closes the connection, waiting at most about a second. For app termination.
    func restoreAutomaticAndClose() {
        queue.sync {
            guard descriptor >= 0 else { return }
            _ = exchange(["command": "setAllAuto"], timeout: 1)
            closeConnection()
        }
    }

    private func exchange(_ request: [String: Any], timeout: Int) -> Result<HelperStatus, HelperFailure> {
        let wasHeld = descriptor >= 0
        let result = attempt(request, timeout: timeout)
        if wasHeld, result == .failure(.broken) {
            return attempt(request, timeout: timeout)
        }
        return result
    }

    private func attempt(_ request: [String: Any], timeout: Int) -> Result<HelperStatus, HelperFailure> {
        let wasHeld = descriptor >= 0
        if descriptor < 0 {
            guard let opened = Self.connect(to: FanHelperLocation.socketPath) else { return .failure(.unreachable) }
            descriptor = opened
        }
        var receiveTimeout = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return .failure(.broken) }
        line.append(UInt8(ascii: "\n"))
        let sent = line.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == line.count, let reply = readLine() else {
            closeConnection()
            return .failure(.broken)
        }
        let result = Self.parse(reply)
        switch result {
        case .success(let status) where status.hasForcedFans:
            watchForClose()
        case .failure(.refused) where wasHeld:
            // Closing now would make the helper release every fan over one rejected request.
            break
        default:
            closeConnection()
        }
        return result
    }

    private func readLine() -> Data? {
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while reply.count < 64 * 1024 {
            let count = recv(descriptor, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            reply.append(contentsOf: chunk[0..<count])
            if chunk[count - 1] == UInt8(ascii: "\n") { return reply }
        }
        return nil
    }

    /// A read source on the held connection wakes only when the helper closes it; no polling.
    private func watchForClose() {
        guard watcher == nil, descriptor >= 0 else { return }
        let watched = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: watched, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let count = recv(watched, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count > 0 {
                var discard = [UInt8](repeating: 0, count: 2048)
                _ = recv(watched, &discard, discard.count, MSG_DONTWAIT)
                return
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            closeConnection()
            DispatchQueue.main.async { self.onConnectionLost?() }
        }
        source.setCancelHandler { close(watched) }
        watcher = source
        source.resume()
    }

    private func closeConnection() {
        if let watcher {
            watcher.cancel()
            self.watcher = nil
        } else if descriptor >= 0 {
            close(descriptor)
        }
        descriptor = -1
    }

    private static func connect(to path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var noSignalPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func parse(_ reply: Data) -> Result<HelperStatus, HelperFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return .failure(.broken) }
        guard object["ok"] as? Bool == true else {
            return .failure(.refused(object["error"] as? String ?? "The fan helper refused the request"))
        }
        let fans = (object["fans"] as? [[String: Any]] ?? []).compactMap { fan -> HelperFan? in
            guard let id = fan["id"] as? Int else { return nil }
            func number(_ key: String) -> Double { (fan[key] as? NSNumber)?.doubleValue ?? 0 }
            return HelperFan(
                id: id,
                rpm: number("rpm"),
                minimum: number("min"),
                maximum: number("max"),
                target: number("target"),
                isManual: fan["manual"] as? Bool ?? false,
                isForcedByHelper: fan["forced"] as? Bool ?? false
            )
        }
        return .success(HelperStatus(version: object["version"] as? Int ?? 0, isDryRun: object["dryRun"] as? Bool ?? false, fans: fans))
    }
}
