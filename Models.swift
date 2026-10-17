import Foundation
import Network

struct RemoteItem: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let size: Int64
    let groupID: UUID?
    let isFolder: Bool
}

struct RemoteGroup: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct RemoteManifest: Codable {
    let host: String
    let items: [RemoteItem]
    let groups: [RemoteGroup]
}

/// A Mac's Bonjour identity. We store this (not an IP) so we can find the Mac again
/// even after its address changes.
struct MacRef: Codable, Hashable {
    var name: String
    var type: String
    var domain: String

    var endpoint: NWEndpoint {
        .service(name: name, type: type, domain: domain, interface: nil)
    }
}

struct DiscoveredMac: Identifiable, Hashable {
    let ref: MacRef
    var id: String { ref.name }
    var name: String { ref.name }
}

enum SyncError: LocalizedError {
    case unreachable
    case unauthorized
    case http(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Can't reach your Mac. Make sure DropHop is running and you're on the same Wi-Fi."
        case .unauthorized:
            return "This iPhone isn't paired with that Mac any more."
        case .http(let code):
            return "The Mac replied with an error (\(code))."
        case .server(let message):
            return message
        }
    }
}
