import AppKit
import CryptoKit
import Network
import Security
import SwiftUI

// MARK: - Wire format
// Deliberately separate from ShelfItem so public share links never leave the Mac.

struct SyncItem: Codable {
    var id: UUID
    var name: String
    var size: Int64
    var groupID: UUID?
    var isFolder: Bool
}

struct SyncGroup: Codable {
    var id: UUID
    var name: String
}

struct SyncManifest: Codable {
    var host: String
    var items: [SyncItem]
    var groups: [SyncGroup]
}

struct PairedDevice: Codable {
    var name: String
    var tokenHash: String      // SHA-256 of the token; the token itself is never stored on the Mac
    var pairedAt: Date
}

private struct Ping: Encodable { var app: String; var name: String; var paired: Bool }
private struct PairRequest: Decodable { var code: String; var deviceName: String? }
private struct PairReply: Encodable { var token: String; var host: String }
private struct LinkReply: Encodable { var url: String }

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]   // lowercased keys
    var body: Data
}

enum SyncResponse {
    case json(Int, Data)
    case file(URL, temporary: Bool)
}

// MARK: - Server

/// Serves the shelf to ONE paired iPhone over the local network.
///  - Advertised over Bonjour as `_drophop._tcp`.
///  - Nothing except /v1/ping and /v1/pair is reachable without the bearer token.
///  - Pairing needs a 6-digit code that only the Mac screen shows (2 min, 5 tries).
///  - Pairing a new phone replaces the old one.
@MainActor
final class SyncServer: ObservableObject {
    @Published private(set) var paired: PairedDevice?
    @Published private(set) var pairingCode: String?
    @Published private(set) var listening = false

    private let store: ShelfStore
    private let queue = DispatchQueue(label: "DropHop.sync")
    private var listener: NWListener?
    private var codeExpiry: Date?
    private var failedAttempts = 0

    private var pairingFile: URL { ShelfStore.root.appendingPathComponent("pairing.json") }

    nonisolated static var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    init(store: ShelfStore) {
        self.store = store
        loadPairing()
    }

    // MARK: Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp)
            l.service = NWListener.Service(name: Self.hostName, type: "_drophop._tcp")
            let q = queue
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                HTTPConnection(conn, server: self, queue: q).start()
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listening = true
                    case .failed(let error):
                        NSLog("DropHop sync: listener failed: \(error)")
                        self.listening = false
                        self.listener?.cancel()
                        self.listener = nil
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        self.start()
                    case .cancelled:
                        self.listening = false
                    default:
                        break
                    }
                }
            }
            l.start(queue: q)
            listener = l
        } catch {
            NSLog("DropHop sync: could not start listener: \(error)")
        }
    }

    // MARK: Pairing

    func beginPairing() {
        let n = String(Int.random(in: 0...999_999))
        let code = String(repeating: "0", count: 6 - n.count) + n
        pairingCode = code
        codeExpiry = Date().addingTimeInterval(120)
        failedAttempts = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 121_000_000_000)
            if self.pairingCode == code { self.cancelPairing() }
        }
    }

    func cancelPairing() {
        pairingCode = nil
        codeExpiry = nil
    }

    func unpair() {
        paired = nil
        try? FileManager.default.removeItem(at: pairingFile)
    }

    private func handlePair(_ req: HTTPRequest) -> SyncResponse {
        guard let code = pairingCode, let expiry = codeExpiry, expiry > Date() else {
            return fail(403, "No pairing in progress. Choose “Pair iPhone…” on your Mac first.")
        }
        guard let body = try? JSONDecoder().decode(PairRequest.self, from: req.body) else {
            return fail(400, "Bad request")
        }
        guard body.code == code else {
            failedAttempts += 1
            if failedAttempts >= 5 { cancelPairing() }
            return fail(403, failedAttempts >= 5 ? "Too many wrong codes. Start pairing again on your Mac." : "Wrong code")
        }
        let token = Self.randomToken()
        paired = PairedDevice(name: body.deviceName ?? "iPhone",
                              tokenHash: Self.hash(token),
                              pairedAt: Date())
        savePairing()
        cancelPairing()
        return json(200, PairReply(token: token, host: Self.hostName))
    }

    private func isAuthorized(_ req: HTTPRequest) -> Bool {
        guard let device = paired,
              let header = req.headers["authorization"],
              header.hasPrefix("Bearer ") else { return false }
        return Self.hash(String(header.dropFirst(7))) == device.tokenHash
    }

    // MARK: Routing

    func route(_ req: HTTPRequest) async -> SyncResponse {
        let path = req.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? req.path

        if req.method == "GET", path == "/v1/ping" {
            return json(200, Ping(app: "DropHop", name: Self.hostName, paired: paired != nil))
        }
        if req.method == "POST", path == "/v1/pair" {
            return handlePair(req)
        }

        // Everything below needs the paired iPhone's token.
        guard isAuthorized(req) else { return fail(401, "Not paired") }

        if req.method == "GET", path == "/v1/manifest" {
            return manifest()
        }
        if req.method == "POST", path.hasPrefix("/v1/files/"), path.hasSuffix("/link") {
            let idString = String(path.dropFirst("/v1/files/".count).dropLast("/link".count))
            guard let id = UUID(uuidString: idString),
                  store.items.contains(where: { $0.id == id }) else {
                return fail(404, "No such file")
            }
            do {
                return json(200, LinkReply(url: try await store.linkForSync(itemID: id)))
            } catch {
                return fail(502, "Upload failed: " + error.localizedDescription)
            }
        }
        if req.method == "GET", path.hasPrefix("/v1/files/") {
            let idString = String(path.dropFirst("/v1/files/".count))
            guard let id = UUID(uuidString: idString),
                  let item = store.items.first(where: { $0.id == id }) else {
                return fail(404, "No such file")
            }
            return await fileResponse(for: item)
        }
        return fail(404, "Not found")
    }

    private func manifest() -> SyncResponse {
        let items = store.items.map { item -> SyncItem in
            let isDir = Self.isDirectory(store.fileURL(item))
            return SyncItem(id: item.id,
                            name: isDir ? item.name + ".zip" : item.name,
                            size: item.size,
                            groupID: item.groupID,
                            isFolder: isDir)
        }
        let groups = store.groups.map { SyncGroup(id: $0.id, name: $0.name) }
        return json(200, SyncManifest(host: Self.hostName, items: items, groups: groups))
    }

    private func fileResponse(for item: ShelfItem) async -> SyncResponse {
        let url = store.fileURL(item)
        guard FileManager.default.fileExists(atPath: url.path) else { return fail(404, "File is gone") }
        if !Self.isDirectory(url) { return .file(url, temporary: false) }

        // Folders are sent as a zip.
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("drophop-\(UUID().uuidString).zip")
        let ok = await Task.detached { Self.zip(url, to: zip) }.value
        return ok ? .file(zip, temporary: true) : fail(500, "Could not zip folder")
    }

    // MARK: Helpers

    private func json<T: Encodable>(_ status: Int, _ value: T) -> SyncResponse {
        .json(status, (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    private func fail(_ status: Int, _ message: String) -> SyncResponse {
        json(status, ["error": message])
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    nonisolated static func zip(_ src: URL, to dest: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dest.path]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure randomness available")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func savePairing() {
        guard let device = paired, let data = try? JSONEncoder().encode(device) else { return }
        try? data.write(to: pairingFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingFile.path)
    }

    private func loadPairing() {
        guard let data = try? Data(contentsOf: pairingFile) else { return }
        paired = try? JSONDecoder().decode(PairedDevice.self, from: data)
    }
}

// MARK: - Minimal HTTP/1.1 connection (one request per connection)

final class HTTPConnection {
    private let conn: NWConnection
    private let server: SyncServer
    private let queue: DispatchQueue
    private var buffer = Data()

    init(_ conn: NWConnection, server: SyncServer, queue: DispatchQueue) {
        self.conn = conn
        self.server = server
        self.queue = queue
    }

    func start() {
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let request = parse() { handle(request); return }
            if error != nil || isComplete || buffer.count > 200_000 { conn.cancel(); return }
            receive()
        }
    }

    private func parse() -> HTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { conn.cancel(); return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= 65_536 else { conn.cancel(); return nil }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: body)
    }

    private func handle(_ request: HTTPRequest) {
        Task {
            let response = await server.route(request)
            send(response)
        }
    }

    private func send(_ response: SyncResponse) {
        switch response {
        case let .json(status, body):
            let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Connection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(body)
            conn.send(content: data, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [conn] _ in conn.cancel() })

        case let .file(url, temporary):
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard let fh = try? FileHandle(forReadingFrom: url) else {
                if temporary { try? FileManager.default.removeItem(at: url) }
                send(.json(404, Data("{\"error\":\"File is gone\"}".utf8)))
                return
            }
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "Content-Length: \(size)\r\n"
                + "Connection: close\r\n\r\n"
            let cleanup: () -> Void = { [conn] in
                try? fh.close()
                if temporary { try? FileManager.default.removeItem(at: url) }
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
            conn.send(content: Data(head.utf8), completion: .contentProcessed { [self] error in
                if error != nil { cleanup(); return }
                pump(fh, cleanup: cleanup)
            })
        }
    }

    // Reads the file in chunks, waiting for each chunk to be handed to the network
    // stack before reading the next, so big files never sit in memory.
    private func pump(_ fh: FileHandle, cleanup: @escaping () -> Void) {
        let chunk = try? fh.read(upToCount: 256 * 1024)
        guard let chunk, !chunk.isEmpty else { cleanup(); return }
        conn.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { cleanup(); return }
            pump(fh, cleanup: cleanup)
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Internal Server Error"
        }
    }
}

// MARK: - Pairing window

struct PairingView: View {
    @ObservedObject var server: SyncServer
    var onDone: () -> Void

    private var spaced: String {
        guard let c = server.pairingCode, c.count == 6 else { return "" }
        return String(c.prefix(3)) + " " + String(c.suffix(3))
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 34))
                .padding(.top, 6)

            if server.pairingCode != nil {
                Text("Enter this code on your iPhone").font(.headline)
                Text(spaced)
                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("Open DropHop on your iPhone (same Wi-Fi), pick this Mac and type the code. It expires in 2 minutes.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let device = server.paired {
                Text("Paired with \(device.name)").font(.headline)
                Text("Files on your shelf now show up in DropHop on that iPhone, and only that iPhone can download them.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Unpair", role: .destructive) { server.unpair() }
                    Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Code expired").font(.headline)
                Button("Get a new code") { server.beginPairing() }
            }

            if server.pairingCode != nil, let device = server.paired {
                Divider().padding(.top, 4)
                HStack {
                    Text("Currently paired: \(device.name)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Unpair") { server.unpair() }.font(.caption)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
