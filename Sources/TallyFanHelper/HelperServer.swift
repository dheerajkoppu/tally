import Foundation

/// Serves the JSON-lines protocol on a Unix socket. Everything runs on the main queue and only wakes for socket
/// events and signals; the one timer is the short idle countdown before exiting.
///
/// Requests, one JSON object per line:
///   {"command":"status"}
///   {"command":"setManual","fan":0,"rpm":3000}
///   {"command":"setAuto","fan":0}
///   {"command":"setAllAuto"}
/// Every reply is `{"ok":true,"version":2,"dryRun":false,"fans":[…]}` or `{"ok":false,"error":"…"}`.
final class HelperServer {
    static let version = 2
    private static let maximumClients = 4
    private static let maximumLineLength = 512

    private final class Client {
        let descriptor: Int32
        let source: DispatchSourceRead
        var buffer: [UInt8] = []
        var hasForcedFans = false

        init(descriptor: Int32, source: DispatchSourceRead) {
            self.descriptor = descriptor
            self.source = source
        }
    }

    private let listener: Int32
    private let driver: FanDriver
    private let allowedUID: uid_t?
    private let idleExitDelay: TimeInterval
    private let markerPath: String
    private let log: (String) -> Void

    private var listenerSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private var clients: [Int32: Client] = [:]
    private var idleExit: DispatchWorkItem?

    init(listener: Int32, driver: FanDriver, allowedUID: uid_t?, idleExitDelay: TimeInterval, markerPath: String, log: @escaping (String) -> Void) {
        self.listener = listener
        self.driver = driver
        self.allowedUID = allowedUID
        self.idleExitDelay = idleExitDelay
        self.markerPath = markerPath
        self.log = log
    }

    func start() {
        if FileManager.default.fileExists(atPath: markerPath) {
            log("Fans were left forced by an earlier run; returning every fan to automatic")
            driver.restoreAll()
            updateMarker()
        }

        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.shutDown(reason: "signal \(signalNumber)") }
            source.resume()
            signalSources.append(source)
        }
        signal(SIGPIPE, SIG_IGN)

        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        listenerSource = source
        scheduleIdleExitIfIdle()
    }

    private func acceptClients() {
        while true {
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { return }
            admit(descriptor)
        }
    }

    private func admit(_ descriptor: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == 0 || peerUID == allowedUID else {
            log("Refused a client with uid \(peerUID)")
            reply(to: descriptor, ["ok": false, "error": "This user may not control the fans"])
            close(descriptor)
            return
        }
        guard clients.count < Self.maximumClients else {
            reply(to: descriptor, ["ok": false, "error": "Too many clients"])
            close(descriptor)
            return
        }
        var noSignalPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        idleExit?.cancel()
        idleExit = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        let client = Client(descriptor: descriptor, source: source)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(from: client)
        }
        source.setCancelHandler { close(descriptor) }
        clients[descriptor] = client
        source.resume()
    }

    private func read(from client: Client) {
        var chunk = [UInt8](repeating: 0, count: 1024)
        let count = recv(client.descriptor, &chunk, chunk.count, 0)
        guard count > 0 else {
            disconnect(client)
            return
        }
        client.buffer.append(contentsOf: chunk[0..<count])
        while let newline = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Array(client.buffer[..<newline])
            client.buffer.removeSubrange(...newline)
            reply(to: client.descriptor, handle(line, from: client))
        }
        if client.buffer.count > Self.maximumLineLength {
            reply(to: client.descriptor, ["ok": false, "error": "Request too long"])
            disconnect(client)
        }
    }

    private func handle(_ line: [UInt8], from client: Client) -> [String: Any] {
        guard line.count <= Self.maximumLineLength,
              let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let request = object as? [String: Any],
              let command = request["command"] as? String
        else { return ["ok": false, "error": "Malformed request"] }

        do {
            switch command {
            case "status":
                break
            case "setManual":
                guard let fan = integer(request["fan"]), let rpm = number(request["rpm"]), rpm.isFinite else {
                    return ["ok": false, "error": "setManual needs a fan and an rpm"]
                }
                // Marked before the first SMC write, so a helper that dies mid-write is restarted and restores the fans.
                writeMarker(forcedFans: Set(driver.forcedFans.keys).union([fan]))
                try driver.setManual(fan, rpm: rpm)
                client.hasForcedFans = true
            case "setAuto":
                guard let fan = integer(request["fan"]) else { return ["ok": false, "error": "setAuto needs a fan"] }
                try driver.setAuto(fan)
            case "setAllAuto":
                driver.restoreAll()
            default:
                return ["ok": false, "error": "Unknown command"]
            }
        } catch {
            updateMarker()
            return ["ok": false, "error": "\(error)"]
        }
        updateMarker()
        if driver.forcedFans.isEmpty {
            for other in clients.values { other.hasForcedFans = false }
        }
        return ["ok": true, "version": Self.version, "dryRun": driver.isDryRun, "fans": driver.status().map(\.dictionary)]
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private func integer(_ value: Any?) -> Int? {
        guard let double = number(value), double.isFinite, double == double.rounded(), abs(double) < 1000 else { return nil }
        return Int(double)
    }

    private func reply(to descriptor: Int32, _ response: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = data.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
    }

    private func disconnect(_ client: Client) {
        clients[client.descriptor] = nil
        client.source.cancel()
        // Also covers a setManual that failed halfway and left a fan forced without marking its client.
        if client.hasForcedFans || !driver.forcedFans.isEmpty, !clients.values.contains(where: \.hasForcedFans) {
            log("The app that forced the fans went away; returning every fan to automatic")
            driver.restoreAll()
            updateMarker()
        }
        scheduleIdleExitIfIdle()
    }

    /// The marker lets launchd restart the helper after a crash (KeepAlive PathState) so it can restore the fans.
    private func updateMarker() {
        writeMarker(forcedFans: Set(driver.forcedFans.keys))
    }

    private func writeMarker(forcedFans: Set<Int>) {
        let forced = forcedFans.sorted()
        if forced.isEmpty {
            unlink(markerPath)
        } else {
            let text = forced.map(String.init).joined(separator: ",") + "\n"
            FileManager.default.createFile(atPath: markerPath, contents: Data(text.utf8), attributes: [.posixPermissions: 0o644])
        }
    }

    private func scheduleIdleExitIfIdle() {
        guard clients.isEmpty, driver.forcedFans.isEmpty, idleExit == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.clients.isEmpty, self.driver.forcedFans.isEmpty else { return }
            self.log("Idle; exiting")
            exit(0)
        }
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleExitDelay, execute: work)
    }

    private func shutDown(reason: String) {
        log("Stopping (\(reason)); returning every fan to automatic")
        if !driver.forcedFans.isEmpty || FileManager.default.fileExists(atPath: markerPath) {
            driver.restoreAll()
        }
        updateMarker()
        exit(0)
    }
}
