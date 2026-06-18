import Foundation

final class RemoteAudioServiceBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onStatusChange: ((String) -> Void)?
    var onServiceFound: ((URL, String) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var isBrowsing = false

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !isBrowsing else {
            return
        }

        isBrowsing = true
        onStatusChange?("Searching for RemoteSound sources...")
        browser.searchForServices(ofType: "_remoteaudio._tcp.", inDomain: "local.")
    }

    func stop() {
        guard isBrowsing else {
            return
        }

        isBrowsing = false
        browser.stop()
        services.removeAll()
        onStatusChange?("Discovery stopped.")
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        onStatusChange?("Searching for RemoteSound sources...")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isBrowsing = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isBrowsing = false
        onStatusChange?("Discovery failed.")
        NSLog("RemoteAudioServiceBrowser.didNotSearch: %@", errorDict)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName,
              sender.port > 0 else {
            return
        }

        var components = URLComponents()
        components.scheme = "ws"
        components.host = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        components.port = sender.port
        components.path = path(from: sender)

        guard let url = components.url else {
            return
        }

        onStatusChange?("Found \(sender.name).")
        onServiceFound?(url, sender.name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("RemoteAudioServiceBrowser.didNotResolve: %@ %@", sender.name, errorDict)
    }

    private func path(from service: NetService) -> String {
        guard let txtRecordData = service.txtRecordData() else {
            return "/"
        }

        let txt = NetService.dictionary(fromTXTRecord: txtRecordData)
        guard let pathData = txt["path"],
              let path = String(data: pathData, encoding: .utf8),
              path.hasPrefix("/") else {
            return "/"
        }

        return path
    }
}
