import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct ShelfGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var link: String?
    var linkExpiry: Date?
}

struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var size: Int64
    var link: String?
    var linkExpiry: Date?
    var groupID: UUID?
}

struct Manifest: Codable {
    var items: [ShelfItem]
    var groups: [ShelfGroup]
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published var items: [ShelfItem] = []
    @Published var groups: [ShelfGroup] = []
    @Published var uploading: Set<UUID> = []   // item ids and group ids
    @Published var errors: [UUID: String] = [:]

    static let root: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("DropHop", isDirectory: true)
        let old = support.appendingPathComponent("ShakeShelf", isDirectory: true)
        // Keep files from the earlier "ShakeShelf" version
        if FileManager.default.fileExists(atPath: old.path),
           !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.moveItem(at: old, to: base)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var manifest: URL { Self.root.appendingPathComponent("items.json") }

    init() { load() }

    func fileURL(_ item: ShelfItem) -> URL {
        Self.root
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.name)
    }

    func groupName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return groups.first { $0.id == id }?.name
    }

    func urls(inGroup id: UUID) -> [URL] {
        items.filter { $0.groupID == id }.map { fileURL($0) }
    }

    // MARK: Items

    // Copy dropped files into the shelf's own storage so they stay available
    // even if the original is moved or deleted.
    // Folders are zipped on the way in, so the shelf only ever holds single files.
    func add(urls: [URL], group: UUID?) {
        for url in urls {
            if ShelfStore.isDirectory(url) {
                addFolderAsZip(url, group: group)
                continue
            }
            let id = UUID()
            let dir = Self.root.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                items.insert(ShelfItem(id: id, name: url.lastPathComponent,
                                       size: Self.size(of: dest), groupID: group), at: 0)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                NSSound.beep()
            }
        }
        save()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    // Zips the folder in the background (big folders can take a while), then shelves the .zip.
    private func addFolderAsZip(_ folder: URL, group: UUID?) {
        let id = UUID()
        let dir = Self.root.appendingPathComponent(id.uuidString, isDirectory: true)
        let zipName = folder.lastPathComponent + ".zip"
        let dest = dir.appendingPathComponent(zipName)
        Task {
            let ok = await Task.detached { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch { return false }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, dest.path]
                do {
                    try p.run()
                    p.waitUntilExit()
                    return p.terminationStatus == 0
                } catch { return false }
            }.value
            if ok {
                items.insert(ShelfItem(id: id, name: zipName,
                                       size: Self.size(of: dest), groupID: group), at: 0)
                save()
            } else {
                try? FileManager.default.removeItem(at: dir)
                NSSound.beep()
            }
        }
    }

    func remove(_ item: ShelfItem) {
        deleteFiles(of: item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear(_ list: [ShelfItem]) {
        let ids = Set(list.map { $0.id })
        for item in list { deleteFiles(of: item) }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func move(_ item: ShelfItem, to group: UUID?) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].groupID = group
            save()
        }
    }

    private func deleteFiles(of item: ShelfItem) {
        try? FileManager.default.removeItem(
            at: Self.root.appendingPathComponent(item.id.uuidString, isDirectory: true))
    }

    // MARK: Groups

    @discardableResult
    func addGroup(_ name: String) -> ShelfGroup {
        let g = ShelfGroup(name: name)
        groups.append(g)
        save()
        return g
    }

    func renameGroup(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = n
        save()
    }

    func deleteGroup(_ id: UUID, deleteFiles removeFiles: Bool) {
        if removeFiles {
            clear(items.filter { $0.groupID == id })
        } else {
            for i in items.indices where items[i].groupID == id { items[i].groupID = nil }
        }
        groups.removeAll { $0.id == id }
        save()
    }

    // MARK: Links

    // Upload one item to a temporary public host and copy the link to the clipboard.
    func makeLink(_ item: ShelfItem, hours: Int) {
        guard !uploading.contains(item.id) else { return }
        uploading.insert(item.id)
        errors[item.id] = nil
        let src = fileURL(item)
        Task {
            do {
                let r = try await Uploader.upload(src, hours: hours)
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].link = r.link
                    items[i].linkExpiry = Date().addingTimeInterval(Double(r.hours) * 3600)
                    save()
                }
                Self.copyToClipboard(r.link)
            } catch {
                errors[item.id] = error.localizedDescription
            }
            uploading.remove(item.id)
        }
    }

    // Upload a whole group as ONE zip file with ONE link.
    func makeGroupLink(_ group: ShelfGroup, hours: Int) {
        let files = urls(inGroup: group.id)
        guard !files.isEmpty, !uploading.contains(group.id) else { return }
        uploading.insert(group.id)
        errors[group.id] = nil
        let name = group.name.replacingOccurrences(of: "/", with: "-")
        Task {
            do {
                let r = try await Uploader.uploadBundle(files, name: name, hours: hours)
                if let i = groups.firstIndex(where: { $0.id == group.id }) {
                    groups[i].link = r.link
                    groups[i].linkExpiry = Date().addingTimeInterval(Double(r.hours) * 3600)
                    save()
                }
                Self.copyToClipboard(r.link)
            } catch {
                errors[group.id] = error.localizedDescription
            }
            uploading.remove(group.id)
        }
    }

    // Used by the iPhone sync: returns a public link for the item (reusing a still-valid one),
    // without touching the Mac's clipboard.
    func linkForSync(itemID: UUID, hours: Int = 24) async throws -> String {
        guard let item = items.first(where: { $0.id == itemID }) else {
            throw NSError(domain: "Link", code: 404, userInfo: [NSLocalizedDescriptionKey: "No such file"])
        }
        if let link = item.link, let expiry = item.linkExpiry, expiry > Date().addingTimeInterval(300) {
            return link
        }
        uploading.insert(itemID)
        errors[itemID] = nil
        defer { uploading.remove(itemID) }
        do {
            let r = try await Uploader.upload(fileURL(item), hours: hours)
            if let i = items.firstIndex(where: { $0.id == itemID }) {
                items[i].link = r.link
                items[i].linkExpiry = Date().addingTimeInterval(Double(r.hours) * 3600)
                save()
            }
            return r.link
        } catch {
            errors[itemID] = error.localizedDescription
            throw error
        }
    }

    static func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: Persistence

    private func save() {
        let m = Manifest(items: items, groups: groups)
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: manifest) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifest) else { return }
        if let m = try? JSONDecoder().decode(Manifest.self, from: data) {
            items = m.items
            groups = m.groups
        } else if let old = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = old            // manifest from the first version of the app
        }
        items = items.filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

// MARK: - AirDrop

enum AirDrop {
    static let service = NSSharingService(named: .sendViaAirDrop)
    static var icon: NSImage? { service?.image }

    static func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let s = service, s.canPerform(withItems: urls) {
                s.perform(withItems: urls)
            } else {
                NSSound.beep()
            }
        }
    }
}

// MARK: - Upload (Litterbox by catbox.moe: free, no account, auto-expiring links)

struct UploadResult {
    let link: String
    let hours: Int      // how long the link will really live (some hosts only offer fixed times)
}

enum Uploader {
    private enum Host: CaseIterable {
        case litterbox, zeroX, tmpfiles
        var name: String {
            switch self {
            case .litterbox: return "litterbox"
            case .zeroX: return "0x0.st"
            case .tmpfiles: return "tmpfiles"
            }
        }
        var maxBytes: Int64 {
            switch self {
            case .litterbox: return 1_000_000_000
            case .zeroX: return 500_000_000
            case .tmpfiles: return 100_000_000
            }
        }
    }

    // Several files -> one zip -> one link
    static func uploadBundle(_ files: [URL], name: String, hours: Int) async throws -> UploadResult {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stage = parent.appendingPathComponent(name.isEmpty ? "DropHop" : name, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        for (i, f) in files.enumerated() {
            var dest = stage.appendingPathComponent(f.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = stage.appendingPathComponent("\(i)-\(f.lastPathComponent)")
            }
            do { try FileManager.default.linkItem(at: f, to: dest) }          // no extra disk use
            catch { try FileManager.default.copyItem(at: f, to: dest) }
        }
        return try await upload(stage, hours: hours)
    }

    static func upload(_ src: URL, hours: Int) async throws -> UploadResult {
        var file = src
        var cleanup: URL?

        // Folders get zipped first.
        if (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let zip = FileManager.default.temporaryDirectory
                .appendingPathComponent(src.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: zip)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", src.path, zip.path]
            try p.run()
            p.waitUntilExit()
            file = zip
            cleanup = zip
        }
        defer { if let c = cleanup { try? FileManager.default.removeItem(at: c) } }

        // Try each free host in turn; if one refuses (blocks, is down, file too big) use the next.
        let size = ShelfStore.size(of: file)
        var failures: [String] = []
        for host in Host.allCases {
            if size > host.maxBytes { failures.append("\(host.name): file too large"); continue }
            do { return try await send(file, to: host, hours: hours) }
            catch { failures.append("\(host.name): \(error.localizedDescription)") }
        }
        let msg = failures.isEmpty ? "Upload failed" : failures.joined(separator: " · ")
        throw NSError(domain: "Upload", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: String(msg.prefix(160))])
    }

    private static func send(_ file: URL, to host: Host, hours: Int) async throws -> UploadResult {
        let endpoint: String
        let fileField: String
        var fields: [(String, String)] = []
        switch host {
        case .litterbox:
            endpoint = "https://litterbox.catbox.moe/resources/internals/api.php"
            fileField = "fileToUpload"
            fields = [("reqtype", "fileupload"), ("time", "\(hours)h")]
        case .zeroX:
            endpoint = "https://0x0.st"
            fileField = "file"
            fields = [("expires", "\(hours)")]
        case .tmpfiles:
            endpoint = "https://tmpfiles.org/api/v1/upload"
            fileField = "file"
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Some hosts reject the default "CFNetwork" user agent with an HTML error page.
        req.setValue("DropHop/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")

        // Build the multipart body on disk so big files don't sit in memory.
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }

        let out = try FileHandle(forWritingTo: body)
        for (name, value) in fields {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let safeName = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        out.write(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8))
        let input = try FileHandle(forReadingFrom: file)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            out.write(chunk)
        }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        // An HTML page instead of a link means the host blocked or rejected us.
        let lower = text.lowercased()
        if lower.hasPrefix("<") || lower.contains("<html") {
            throw NSError(domain: "Upload", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "refused the upload (HTTP \(code))"])
        }

        switch host {
        case .litterbox, .zeroX:
            guard (200..<300).contains(code), text.hasPrefix("http") else {
                throw NSError(domain: "Upload", code: code, userInfo: [NSLocalizedDescriptionKey:
                    text.isEmpty ? "HTTP \(code)" : String(text.prefix(80))])
            }
            return UploadResult(link: text.components(separatedBy: .whitespacesAndNewlines).first ?? text,
                                hours: hours)
        case .tmpfiles:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = json["data"] as? [String: Any],
                  var url = d["url"] as? String else {
                throw NSError(domain: "Upload", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
            }
            url = url.replacingOccurrences(of: "http://", with: "https://")
                     .replacingOccurrences(of: "tmpfiles.org/", with: "tmpfiles.org/dl/")
            return UploadResult(link: url, hours: 1)       // tmpfiles keeps files for 1 hour
        }
    }
}

// MARK: - Shake detection

@MainActor
final class ShakeMonitor {
    var onShake: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var tokens: [Any] = []
    private let dragPB = NSPasteboard(name: .drag)
    private var downCount = 0
    private var lastX: CGFloat = 0
    private var dir = 0
    private var seg: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var fired = false

    func start() {
        if let t = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown()
        }) { tokens.append(t) }
        if let t = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.mouseDragged()
        }) { tokens.append(t) }
        if let t = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseUp()
        }) { tokens.append(t) }
    }

    private func mouseDown() {
        downCount = dragPB.changeCount
        lastX = NSEvent.mouseLocation.x
        dir = 0; seg = 0; reversals = []; fired = false
    }

    private func mouseUp() {
        fired = false
        onDragEnd?()
    }

    private func mouseDragged() {
        // Only react if a file drag actually started (drag pasteboard changed and holds files).
        guard !fired, dragPB.changeCount != downCount else { return }
        guard dragPB.canReadObject(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let x = NSEvent.mouseLocation.x
        let dx = x - lastX
        lastX = x
        guard dx != 0 else { return }

        let d = dx > 0 ? 1 : -1
        if d == dir {
            seg += abs(dx)
        } else {
            if dir != 0 && seg >= 30 { reversals.append(now) }   // a real back-and-forth stroke
            dir = d
            seg = abs(dx)
        }
        reversals.removeAll { now - $0 > 0.9 }
        if reversals.count >= 3 {
            fired = true
            reversals = []
            onShake?()
        }
    }
}

// MARK: - UI

// The window is resizable and sizes itself to the screen (see AppDelegate); the UI just fills it.
let panelMinSize = NSSize(width: 300, height: 340)
let panelMaxSize = NSSize(width: 560, height: 900)

// Two primary colors (warm black + cream) and ONE accent (orange).
// Everything else is just one of those at a lower opacity.
enum Theme {
    static let ink    = Color(red: 0.075, green: 0.067, blue: 0.063)    // #131110
    static let paper  = Color(red: 0.953, green: 0.933, blue: 0.902)    // #F3EEE6
    static let accent = Color(red: 0.949, green: 0.396, blue: 0.176)    // #F2652D
    static let dim     = Theme.paper.opacity(0.50)
    static let surface = Theme.paper.opacity(0.06)
    static let line    = Theme.paper.opacity(0.12)
}

extension Text {
    // small spaced-out monospaced label, like "PERFORMANCE" / "ON THE SHELF" in the reference
    func mono(_ size: CGFloat = 9) -> Text {
        self.font(.system(size: size, weight: .medium, design: .monospaced)).tracking(1.2)
    }
}

final class UIState: ObservableObject {
    @Published var targeted = false
    @Published var selected: UUID? = nil     // nil = "All"
    @Published var adding = false
    @Published var renaming = false
    @Published var draft = ""
}

// Invisible strip that moves the whole window when dragged. Used behind the header,
// the chip bar and the footer, because the file list (a ScrollView with draggable rows)
// swallows every click, so "move by window background" alone stops working once
// there are files on the shelf.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Little corner grip that resizes the window (top-left stays put).
struct ResizeGrip: NSViewRepresentable {
    final class GripView: NSView {
        private var startMouse = NSPoint.zero
        private var startFrame = NSRect.zero
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.953, green: 0.933, blue: 0.902, alpha: 0.45).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            for off in [CGFloat(4), 8, 12] {
                path.move(to: NSPoint(x: bounds.width - off - 1, y: 1))
                path.line(to: NSPoint(x: bounds.width - 1, y: off + 1))
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let m = NSEvent.mouseLocation
            let width  = min(max(startFrame.width + (m.x - startMouse.x), w.minSize.width), w.maxSize.width)
            let height = min(max(startFrame.height - (m.y - startMouse.y), w.minSize.height), w.maxSize.height)
            w.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height),
                       display: true)
        }
    }
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Thin-stroke icon inside an outlined circle
struct RoundIcon: View {
    let name: String
    var size: CGFloat = 26
    var tint: Color = Theme.paper.opacity(0.85)
    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Circle())
    }
}

struct AirDropButton: View {
    let urls: [URL]
    var body: some View {
        Button { AirDrop.send(urls) } label: {
            RoundIcon(name: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.plain)
        .help("Send via AirDrop")
    }
}

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @StateObject private var ui = UIState()
    @State private var compact = false          // true when the window is small
    var onClose: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    private var visible: [ShelfItem] {
        guard let g = ui.selected else { return store.items }
        return store.items.filter { $0.groupID == g }
    }
    private var selectedGroup: ShelfGroup? {
        guard let id = ui.selected else { return nil }
        return store.groups.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            chipBar
            if let g = selectedGroup { groupBar(g) }
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { g in
            Color.clear.task(id: g.size) {
                compact = g.size.width < 340 || g.size.height < 400
            }
        })
        .foregroundColor(Theme.paper)
        .background(
            ZStack {
                Theme.ink
                // soft warm glow in the corner, like the charging tile
                RadialGradient(colors: [Theme.accent.opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 320)
            }
        )
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            LinearGradient(colors: [Theme.paper.opacity(0.22), Theme.paper.opacity(0.04)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .tint(Theme.accent)
        .environment(\.colorScheme, .dark)
    }

    // Big light number + label, clear + close
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(selectedGroup?.name.uppercased() ?? "ON THE SHELF")
                    .mono(9).foregroundColor(Theme.dim).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(visible.count)")
                        .font(.system(size: compact ? 34 : 46, weight: .ultraLight))
                        .tracking(-1.5)
                    Text(visible.count == 1 ? "item" : "items")
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(Theme.dim)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if !visible.isEmpty {
                    Button { store.clear(visible) } label: {
                        Text("CLEAR").mono(9)
                            .foregroundColor(Theme.paper.opacity(0.8))
                            .padding(.horizontal, 11).frame(height: 26)
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onClose) { RoundIcon(name: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, compact ? 14 : 20).padding(.top, compact ? 10 : 16).padding(.bottom, compact ? 4 : 8)
        .background(WindowDragArea())
    }

    // "All" + one chip per group + "+" to make a new group
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", isSelected: ui.selected == nil, group: nil)
                ForEach(store.groups) { g in
                    chip(g.name, isSelected: ui.selected == g.id, group: g.id)
                }
                if ui.adding {
                    TextField("Group name", text: $ui.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .frame(width: 130)
                        .background(Capsule().fill(Theme.surface))
                        .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
                        .onSubmit { commitNewGroup() }
                    Button { ui.adding = false } label: { RoundIcon(name: "xmark", size: 24) }
                        .buttonStyle(.plain)
                } else {
                    Button {
                        ui.draft = ""
                        ui.renaming = false
                        ui.adding = true
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        RoundIcon(name: "plus", size: 24)
                    }
                    .buttonStyle(.plain).help("New group")
                }
            }
            .padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 4 : 8)
        }
        .background(WindowDragArea())
    }

    private func chip(_ title: String, isSelected: Bool, group: UUID?) -> some View {
        Button {
            ui.selected = group
            ui.renaming = false
        } label: {
            Text(title.uppercased()).mono(9)
                .lineLimit(1)
                .foregroundColor(isSelected ? Theme.ink : Theme.paper.opacity(0.7))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Theme.paper : Color.clear))
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.line, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // You can also drop files straight onto a chip to put them in that group.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers, group: group)
        }
    }

    // Actions for the selected group: AirDrop all, one link for all, rename, delete
    private func groupBar(_ g: ShelfGroup) -> some View {
        let linkActive = g.link != nil && (g.linkExpiry ?? .distantFuture) > Date()
        return HStack(spacing: 8) {
            if ui.renaming {
                TextField("Group name", text: $ui.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
                    .onSubmit { finishRename(g) }
                Button { finishRename(g) } label: {
                    Text("DONE").mono(9)
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(Capsule().fill(Theme.paper))
                }
                .buttonStyle(.plain)
            } else {
                if let err = store.errors[g.id] {
                    Text(err).font(.caption2).foregroundColor(Theme.accent).lineLimit(2)
                } else if linkActive, let link = g.link {
                    Text(link).font(.system(size: 10)).foregroundColor(Theme.accent)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("GROUP · \(visible.count) ITEM\(visible.count == 1 ? "" : "S")")
                        .mono(9).foregroundColor(Theme.dim)
                }
                Spacer(minLength: 4)

                AirDropButton(urls: store.urls(inGroup: g.id))
                    .disabled(visible.isEmpty)
                    .opacity(visible.isEmpty ? 0.4 : 1)

                if store.uploading.contains(g.id) {
                    ProgressView().controlSize(.small)
                } else if linkActive, let link = g.link {
                    Button { ShelfStore.copyToClipboard(link) } label: {
                        RoundIcon(name: "doc.on.doc", tint: Theme.accent)
                    }
                    .buttonStyle(.plain).help("Copy group link")
                } else {
                    Menu {
                        Button("Group link (zip) – 1 hour") { store.makeGroupLink(g, hours: 1) }
                        Button("Group link (zip) – 12 hours") { store.makeGroupLink(g, hours: 12) }
                        Button("Group link (zip) – 24 hours") { store.makeGroupLink(g, hours: 24) }
                        Button("Group link (zip) – 72 hours") { store.makeGroupLink(g, hours: 72) }
                    } label: { RoundIcon(name: "link") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(visible.isEmpty)
                        .opacity(visible.isEmpty ? 0.4 : 1)
                        .help("One shareable link for the whole group")
                }

                Menu {
                    Button("Rename group") {
                        ui.draft = g.name
                        ui.renaming = true
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Button("Delete group (keep files)") {
                        store.deleteGroup(g.id, deleteFiles: false)
                        ui.selected = nil
                    }
                    Button("Delete group and its files") {
                        store.deleteGroup(g.id, deleteFiles: true)
                        ui.selected = nil
                    }
                } label: { RoundIcon(name: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    private var content: some View {
        ZStack {
            if visible.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().strokeBorder(ui.targeted ? Theme.accent : Theme.line, lineWidth: 1)
                            .frame(width: 68, height: 68)
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 25, weight: .light))
                            .foregroundColor(ui.targeted ? Theme.accent : Theme.paper.opacity(0.8))
                    }
                    Text(selectedGroup == nil ? "Drop files here"
                                              : "Drop files into \(selectedGroup?.name ?? "group")")
                        .font(.system(size: 15, weight: .light))
                        .foregroundColor(Theme.paper.opacity(0.7))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { item in
                            ItemRow(store: store, item: item, showGroup: ui.selected == nil, compact: compact)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(ui.targeted ? Theme.accent : (visible.isEmpty ? Theme.line : Color.clear),
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(ui.targeted ? Theme.accent.opacity(0.08) : Color.clear))
                .padding(.horizontal, 14).padding(.vertical, 4)
                .allowsHitTesting(false)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $ui.targeted) { providers in
            handleDrop(providers, group: ui.selected)
        }
    }

    // Bottom strip: grab here to move the shelf, drag the corner grip to resize it
    private var footer: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10))
                    Text("DRAG HERE TO MOVE").mono(8)
                    Spacer(minLength: 8)
                    Text("⌥ DRAG ANYWHERE").mono(8)
                }
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10))
                    Text("DRAG HERE TO MOVE").mono(8)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10))
                    Spacer(minLength: 0)
                }
            }
            ResizeGrip().frame(width: 16, height: 16)
        }
        .foregroundColor(Theme.paper.opacity(0.35))
        .padding(.leading, compact ? 14 : 20).padding(.trailing, 14)
        .padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
    }

    private func handleDrop(_ providers: [NSItemProvider], group: UUID?) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.add(urls: [url], group: group) } }
            }
        }
        return true
    }

    private func commitNewGroup() {
        let name = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let g = store.addGroup(name)
            ui.selected = g.id
        }
        ui.adding = false
    }

    private func finishRename(_ g: ShelfGroup) {
        store.renameGroup(g.id, to: ui.draft)
        ui.renaming = false
    }
}

struct ItemRow: View {
    @ObservedObject var store: ShelfStore
    let item: ShelfItem
    let showGroup: Bool
    var compact: Bool = false

    var body: some View {
        let url = store.fileURL(item)
        let linkActive = item.link != nil && (item.linkExpiry ?? .distantFuture) > Date()
        var subtitle = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        if showGroup, let g = store.groupName(item.groupID) { subtitle += " · \(g)" }

        return HStack(spacing: 11) {
            // file icon sits on a cream tile, like the cappuccino card
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper.opacity(0.94))
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            }
            .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1).truncationMode(.middle)
                if let err = store.errors[item.id] {
                    Text(err).font(.caption2).foregroundColor(Theme.accent).lineLimit(2)
                } else if linkActive, let link = item.link {
                    Text(link).font(.system(size: 10)).foregroundColor(Theme.accent)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(subtitle).font(.system(size: 10)).foregroundColor(Theme.dim)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)

            HStack(spacing: compact ? 4 : 6) {
                AirDropButton(urls: [url])

                if store.uploading.contains(item.id) {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else if linkActive, let link = item.link {
                    Button { ShelfStore.copyToClipboard(link) } label: {
                        RoundIcon(name: "doc.on.doc", tint: Theme.accent)
                    }
                    .buttonStyle(.plain).help("Copy link")
                } else {
                    Menu {
                        Button("Link valid for 1 hour") { store.makeLink(item, hours: 1) }
                        Button("Link valid for 12 hours") { store.makeLink(item, hours: 12) }
                        Button("Link valid for 24 hours") { store.makeLink(item, hours: 24) }
                        Button("Link valid for 72 hours") { store.makeLink(item, hours: 72) }
                    } label: { RoundIcon(name: "link") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Create shareable link")
                }

                Button { store.remove(item) } label: { RoundIcon(name: "xmark") }
                    .buttonStyle(.plain).help("Remove from shelf")
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        // Drag the file out of the shelf into any app / window / email / chat.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Menu("Move to group") {
                Button("No group") { store.move(item, to: nil) }
                ForEach(store.groups) { g in
                    Button(g.name) { store.move(item, to: g.id) }
                }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove") { store.remove(item) }
        }
    }
}

// MARK: - Floating panel + app

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ShelfStore()
    lazy var sync = SyncServer(store: store)
    let monitor = ShakeMonitor()
    var panel: ShelfPanel!
    var statusItem: NSStatusItem!
    var pairWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: ShelfView(store: store, onClose: { [weak self] in
            self?.panel.orderOut(nil)
        }))
        host.sizingOptions = []                       // window size is ours, not the content's

        // Size the shelf to the screen it's on: roomy on big displays, compact on small ones.
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: min(max(vf.width * 0.24, 340), 420),
                          height: min(max(vf.height * 0.62, 440), min(640, vf.height - 40)))
        host.frame = NSRect(origin: .zero, size: size)

        panel = ShelfPanel(contentRect: host.frame,
                           styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
                           backing: .buffered, defer: false)
        panel.contentView = host
        panel.minSize = panelMinSize
        panel.maxSize = panelMaxSize
        panel.setFrameAutosaveName("DropHopShelf")    // remembers the size you chose
        panel.isFloatingPanel = true
        panel.level = .floating                       // stays above other windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false               // survives opening/closing other windows
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)

        monitor.onShake = { [weak self] in self?.showPanel(near: NSEvent.mouseLocation) }
        monitor.onDragEnd = { [weak self] in
            // If you shook but never dropped anything, tuck the shelf away again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self, self.store.items.isEmpty else { return }
                self.panel.orderOut(nil)
            }
        }
        monitor.start()
        sync.start()          // lets your paired iPhone see and download the shelf

        // Hold Option and drag from anywhere (even over file rows) to move the shelf.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.panel, event.modifierFlags.contains(.option) {
                self.panel.performDrag(with: event)
                return nil
            }
            return event
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                                           accessibilityDescription: "DropHop")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show DropHop", action: #selector(showFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pair iPhone…", action: #selector(pairIPhone), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DropHop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func showFromMenu() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        fitToScreen(vf)
        panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 20,
                                     y: vf.midY - panel.frame.height / 2))
        panel.orderFrontRegardless()
    }

    // If the saved size doesn't fit this screen (smaller display, different monitor), shrink it.
    private func fitToScreen(_ vf: NSRect) {
        var size = panel.frame.size
        size.width = min(size.width, vf.width - 20)
        size.height = min(size.height, vf.height - 20)
        if size != panel.frame.size { panel.setContentSize(size) }
    }

    @objc func clearShelf() { store.clear(store.items) }

    @objc func pairIPhone() {
        sync.beginPairing()
        if pairWindow == nil {
            let view = PairingView(server: sync, onDone: { [weak self] in self?.pairWindow?.close() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Pair iPhone"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sync.cancelPairing() }
            }
            pairWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        pairWindow?.makeKeyAndOrderFront(nil)
    }

    func showPanel(near p: NSPoint) {
        guard !panel.isVisible else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        fitToScreen(vf)
        let size = panel.frame.size

        var x = p.x + 40
        if x + size.width > vf.maxX - 10 { x = p.x - 40 - size.width }
        x = min(max(x, vf.minX + 10), vf.maxX - size.width - 10)
        let y = min(max(p.y - size.height / 2, vf.minY + 10), vf.maxY - size.height - 10)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }
}

@main
struct DropHopApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}
