import Foundation
import Combine
import Network
import UIKit

private struct PairBody: Encodable { let code: String; let deviceName: String }
private struct PairReply: Decodable { let token: String; let host: String }
private struct ErrorBody: Decodable { let error: String }

@MainActor
final class SyncClient: ObservableObject {
    enum Status: Equatable {
        case unpaired
        case connecting
        case online(String)     // Mac's name
        case offline
    }

    @Published private(set) var status: Status = .unpaired
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var groups: [RemoteGroup] = []
    @Published private(set) var progress: [UUID: Double] = [:]      // items being downloaded
    @Published private(set) var failures: [UUID: String] = [:]
    @Published private(set) var local: [UUID: String] = [:]         // item id → file name in Documents
    @Published var notice: String?

    private let defaults = UserDefaults.standard
    private var token: String?
    private var mac: MacRef?
    private var baseURL: URL?
    private let downloader = Downloader()

    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        token = Keychain.get("token")
        if let data = defaults.data(forKey: "mac") {
            mac = try? JSONDecoder().decode(MacRef.self, from: data)
        }
        if let saved = defaults.dictionary(forKey: "local") as? [String: String] {
            for (k, v) in saved { if let id = UUID(uuidString: k) { local[id] = v } }
        }
        status = (token != nil && mac != nil) ? .connecting : .unpaired
    }

    // MARK: Pairing

    func pair(with mac: MacRef, code: String) async throws {
        let base = try await Resolver.baseURL(for: mac.endpoint)
        var req = URLRequest(url: base.appendingPathComponent("v1/pair"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PairBody(code: code, deviceName: UIDevice.current.name))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.unreachable }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw SyncError.server(message ?? "Pairing failed (\(http.statusCode)).")
        }
        let reply = try JSONDecoder().decode(PairReply.self, from: data)

        Keychain.set(reply.token, for: "token")
        defaults.set(try? JSONEncoder().encode(mac), forKey: "mac")
        token = reply.token
        self.mac = mac
        baseURL = base
        status = .connecting
        await refresh()
    }

    /// Forget the Mac on this iPhone. (Downloaded files stay.)
    func unpair() {
        Keychain.delete("token")
        defaults.removeObject(forKey: "mac")
        token = nil
        mac = nil
        baseURL = nil
        items = []
        groups = []
        status = .unpaired
    }

    // MARK: Syncing

    func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    func refresh() async {
        guard token != nil, let mac else { return }
        do {
            if baseURL == nil {
                if case .online = status {} else { status = .connecting }
                baseURL = try await Resolver.baseURL(for: mac.endpoint)
            }
            let (data, resp) = try await URLSession.shared.data(for: try request("v1/manifest"))
            guard let http = resp as? HTTPURLResponse else { throw SyncError.unreachable }
            if http.statusCode == 401 { throw SyncError.unauthorized }
            guard http.statusCode == 200 else { throw SyncError.http(http.statusCode) }
            let manifest = try JSONDecoder().decode(RemoteManifest.self, from: data)
            if items != manifest.items { items = manifest.items }
            if groups != manifest.groups { groups = manifest.groups }
            status = .online(manifest.host)
        } catch SyncError.unauthorized {
            unpair()
            notice = "That Mac no longer recognises this iPhone. Pair again to continue."
        } catch {
            baseURL = nil       // the Mac's address may have changed; look it up again next time
            if !Task.isCancelled { status = .offline }
        }
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let baseURL, let token else { throw SyncError.unreachable }
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: Downloads

    func download(_ item: RemoteItem) async {
        guard progress[item.id] == nil else { return }
        progress[item.id] = 0
        failures[item.id] = nil
        defer { progress[item.id] = nil }
        do {
            var req = try request("v1/files/\(item.id.uuidString)")
            req.timeoutInterval = 300      // a big folder can take a while to zip on the Mac
            let staged = try await downloader.download(req) { [weak self] p in
                Task { @MainActor in
                    guard let self, self.progress[item.id] != nil else { return }
                    self.progress[item.id] = p
                }
            }
            let dest = uniqueDestination(for: item.name)
            try FileManager.default.moveItem(at: staged, to: dest)
            local[item.id] = dest.lastPathComponent
            saveLocal()
        } catch SyncError.unauthorized {
            unpair()
            notice = "That Mac no longer recognises this iPhone. Pair again to continue."
        } catch {
            failures[item.id] = (error as? SyncError)?.errorDescription ?? error.localizedDescription
        }
    }

    func localURL(for item: RemoteItem) -> URL? {
        guard let name = local[item.id] else { return nil }
        let url = Self.documents.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func removeLocal(_ item: RemoteItem) {
        if let url = localURL(for: item) { try? FileManager.default.removeItem(at: url) }
        local[item.id] = nil
        saveLocal()
    }

    private func uniqueDestination(for name: String) -> URL {
        let safe = (name as NSString).lastPathComponent      // never let a name escape Documents
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = Self.documents.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = Self.documents.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func saveLocal() {
        defaults.set(Dictionary(uniqueKeysWithValues: local.map { ($0.key.uuidString, $0.value) }),
                     forKey: "local")
    }
}
