import Foundation

enum UnixSocket {
    /// Binds a listening socket that only its owner can connect to. Used when testing without launchd.
    static func listen(at path: String) -> Int32? {
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
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
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 4) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// The listening socket launchd created from the plist's Sockets entry.
    static func activateFromLaunchd(name: String) -> Int32? {
        var descriptors: UnsafeMutablePointer<Int32>?
        var count = 0
        let status = withUnsafeMutablePointer(to: &descriptors) { slot in
            slot.withMemoryRebound(to: UnsafeMutablePointer<Int32>.self, capacity: 1) { launch_activate_socket(name, $0, &count) }
        }
        guard status == 0, let descriptors else { return nil }
        defer { free(descriptors) }
        return count > 0 ? descriptors[0] : nil
    }
}
