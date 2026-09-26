import Darwin
import Foundation

/// Runs a short-lived system tool and captures its output, killing it if it overruns.
/// The tool runs at the caller's QoS, so a background caller keeps it on the efficiency cores.
enum CommandRunner {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child, and it gets default signal handling.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_set_qos_class_np(&attributes, qos_class_self())

        let argumentPointers = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argumentPointers.forEach { free($0) } }

        var childPid: pid_t = 0
        let spawnStatus = posix_spawn(&childPid, path, &actions, &attributes, argumentPointers, environ)
        close(writeEnd)
        guard spawnStatus == 0 else {
            close(readEnd)
            return nil
        }

        var output = [UInt8]()
        output.reserveCapacity(64 * 1024)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                break
            }
            var pollDescriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000) + 1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                timedOut = true
                break
            }
            let count = read(readEnd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }
        close(readEnd)
        if timedOut { kill(childPid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(childPid, &status, 0) < 0 && errno == EINTR {}
        return timedOut ? nil : String(decoding: output, as: UTF8.self)
    }
}
