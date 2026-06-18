import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum LocalNetworkAddressProvider {
    static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let firstAddress = pointer else {
            return addresses
        }

        defer { freeifaddrs(pointer) }

        for interface in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            guard isUp, !isLoopback else {
                continue
            }

            guard let socketAddress = interface.pointee.ifa_addr else {
                continue
            }

            let addressFamily = socketAddress.pointee.sa_family
            guard addressFamily == UInt8(AF_INET) else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                let address = String(cString: hostBuffer)
                addresses.append(address)
            }
        }

        return Array(Set(addresses)).sorted()
    }
}
