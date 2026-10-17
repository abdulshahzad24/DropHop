import Foundation
import Combine
import Network

/// Finds Macs running DropHop on the local network.
@MainActor
final class MacBrowser: ObservableObject {
    @Published private(set) var macs: [DiscoveredMac] = []
    private var browser: NWBrowser?

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: "_drophop._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredMac? in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                return DiscoveredMac(ref: MacRef(name: name, type: type, domain: domain))
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.macs = found }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// URLSession can't talk to a Bonjour service name directly, so we open a throwaway
/// connection to the service, read the IPv4 address it resolved to, and use that.
enum Resolver {
    static func baseURL(for endpoint: NWEndpoint, timeout: TimeInterval = 6) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: params)
            var finished = false

            func finish(_ result: Result<URL, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                cont.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        var address: String?
                        switch host {
                        case .ipv4(let a): address = a.debugDescription
                        case .name(let n, _): address = n
                        default: break
                        }
                        if var address {
                            if let i = address.firstIndex(of: "%") { address = String(address[..<i]) }
                            if let url = URL(string: "http://\(address):\(port.rawValue)") {
                                finish(.success(url))
                                return
                            }
                        }
                    }
                    finish(.failure(SyncError.unreachable))
                case .failed:
                    finish(.failure(SyncError.unreachable))
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(SyncError.unreachable))
            }
        }
    }
}
