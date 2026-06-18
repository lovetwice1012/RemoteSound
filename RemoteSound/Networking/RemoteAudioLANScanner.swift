import Foundation
import Network

final class RemoteAudioLANScanner {
    var onStatusChange: ((String) -> Void)?
    var onServerFound: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "RemoteSound.LANScanner")
    private var connections: [NWConnection] = []
    private var isScanning = false
    private let scanPort: UInt16

    init(scanPort: UInt16 = 8_766) {
        self.scanPort = scanPort
    }

    func scan() {
        queue.async {
            guard !self.isScanning else {
                return
            }

            let candidates = Self.candidateHosts(from: LocalNetworkAddressProvider.ipv4Addresses())
            guard !candidates.isEmpty else {
                self.onStatusChange?("No local IPv4 network found.")
                return
            }

            self.isScanning = true
            self.onStatusChange?("Scanning local network for RemoteSound sources...")
            self.scan(candidates: candidates)
        }
    }

    func stop() {
        queue.async {
            self.finishScan()
        }
    }

    private func scan(candidates: [String]) {
        let port = NWEndpoint.Port(rawValue: scanPort)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        var pendingCount = candidates.count
        var didFindServer = false

        for host in candidates {
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            connections.append(connection)

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self else {
                    return
                }

                self.queue.async {
                    guard self.isScanning, !didFindServer else {
                        connection?.cancel()
                        return
                    }

                    switch state {
                    case .ready:
                        didFindServer = true
                        let urlString = "http://\(host):\(self.scanPort)/stream.m3u8"
                        self.onStatusChange?("Found RemoteSound source at \(urlString)")
                        if let url = URL(string: urlString) {
                            self.onServerFound?(url)
                        }
                        self.finishScan()
                    case .failed, .cancelled:
                        pendingCount -= 1
                        if pendingCount <= 0 {
                            self.onStatusChange?("No RemoteSound source found on the local subnet.")
                            self.finishScan()
                        }
                    default:
                        break
                    }
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 0.55) { [weak self, weak connection] in
                guard let self, self.isScanning, !didFindServer else {
                    return
                }

                connection?.cancel()
            }
        }
    }

    private func finishScan() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isScanning = false
    }

    private static func candidateHosts(from addresses: [String]) -> [String] {
        var hosts: [String] = []

        for address in addresses {
            let octets = address.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4,
                  octets[0] != 127,
                  octets[0] != 169 else {
                continue
            }

            let prefix = "\(octets[0]).\(octets[1]).\(octets[2])"
            for lastOctet in 1...254 where lastOctet != octets[3] {
                hosts.append("\(prefix).\(lastOctet)")
            }
        }

        return Array(Set(hosts)).sorted()
    }
}
