import QuickLook
import SwiftUI

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var client: SyncClient

    var body: some View {
        Group {
            if client.status == .unpaired {
                PairView()
            } else {
                ShelfView()
            }
        }
        .alert("DropHop", isPresented: Binding(get: { client.notice != nil },
                                               set: { if !$0 { client.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(client.notice ?? "")
        }
    }
}

// MARK: - Pairing

struct PairView: View {
    @StateObject private var browser = MacBrowser()
    @State private var selected: DiscoveredMac?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if browser.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for DropHop on your Wi-Fi…").foregroundColor(.secondary)
                        }
                    }
                    ForEach(browser.macs) { mac in
                        Button { selected = mac } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                    }
                } header: {
                    Text("Your Macs")
                } footer: {
                    Text("On your Mac, click the DropHop icon in the menu bar and choose “Pair iPhone…”. Then pick that Mac here and type the code it shows.")
                }
            }
            .navigationTitle("Connect to your Mac")
            .sheet(item: $selected) { mac in
                CodeEntrySheet(mac: mac)
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}

struct CodeEntrySheet: View {
    let mac: DiscoveredMac
    @EnvironmentObject var client: SyncClient
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(.title, design: .monospaced))
                        .focused($focused)
                        .onChange(of: code) { new in
                            let cleaned = String(new.filter(\.isNumber).prefix(6))
                            if cleaned != new { code = cleaned }
                        }
                } footer: {
                    Text("The code is shown on \(mac.name).")
                }
                if let errorText {
                    Section { Text(errorText).foregroundColor(.red) }
                }
            }
            .navigationTitle("Pair with \(mac.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Pair") { Task { await submit() } }
                            .disabled(code.count != 6)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        busy = true
        errorText = nil
        do {
            try await client.pair(with: mac.ref, code: code)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            busy = false
        }
    }
}

// MARK: - Shelf

struct ShelfView: View {
    @EnvironmentObject var client: SyncClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: URL?
    @State private var confirmUnpair = false
    @State private var showFilesOnly = false

    private var visibleItems: [RemoteItem] {
        let ordered = client.groups.flatMap { group in
            client.items.filter { $0.groupID == group.id }
        } + client.items.filter { item in
            item.groupID == nil || !client.groups.contains(where: { $0.id == item.groupID })
        }
        return showFilesOnly ? ordered.filter { !$0.isFolder } : ordered
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.18, green: 0.10, blue: 0.08), Color(red: 0.075, green: 0.065, blue: 0.06), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                filterBar
                if visibleItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(visibleItems) { item in
                                ShelfItemCard(item: item) { url in preview = url }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                    }
                    .refreshable { await client.refresh() }
                }
                Spacer(minLength: 0)
                footer
            }
        }
        .preferredColorScheme(.dark)
        .quickLookPreview($preview)
        .task(id: scenePhase) {
            if scenePhase == .active { await client.pollLoop() }
        }
        .confirmationDialog("Unpair this iPhone from your Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("Files you already downloaded stay on this iPhone. To also revoke access on the Mac, choose ‘Pair iPhone…’ there and tap Unpair.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ON THE SHELF")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.1)
                    .foregroundStyle(Color.white.opacity(0.56))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(visibleItems.count)")
                        .font(.system(size: 42, weight: .light, design: .rounded))
                        .foregroundStyle(.white)
                    Text(visibleItems.count == 1 ? "item" : "items")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            Spacer()
            Button { Task { await client.refresh() } } label: {
                Text("SYNC")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .padding(.horizontal, 15)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.045), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button { confirmUnpair = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.035), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unpair")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    private var filterBar: some View {
        HStack(spacing: 9) {
            filterPill("ALL", selected: !showFilesOnly) { showFilesOnly = false }
            filterPill("FILES", selected: showFilesOnly) { showFilesOnly = true }
            Button { Task { await client.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(width: 39, height: 39)
                    .background(Color.white.opacity(0.025), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
            statusDot
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
    }

    private func filterPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.7)
                .foregroundStyle(selected ? Color(red: 0.12, green: 0.10, blue: 0.09) : Color.white.opacity(0.65))
                .padding(.horizontal, 18)
                .frame(height: 39)
                .background(selected ? Color(red: 0.96, green: 0.93, blue: 0.87) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var statusDot: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(statusText.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        if case .online = client.status { return Color(red: 0.42, green: 0.83, blue: 0.58) }
        if case .connecting = client.status { return .orange }
        return Color.white.opacity(0.3)
    }

    private var statusText: String {
        switch client.status {
        case .online(let host): return host
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        case .unpaired: return "Unpaired"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 35, weight: .light))
                .foregroundStyle(Color.white.opacity(0.38))
            Text("Nothing on your shelf yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
            Text("Drop a file onto the DropHop shelf on your Mac and it will appear here.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.48))
                .padding(.horizontal, 35)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
            Text("DROP HOP")
                .tracking(2)
            Spacer()
            Text("PULL DOWN TO SYNC")
                .tracking(1.2)
            Image(systemName: "arrow.down")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.28))
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundColor(.secondary)
        }
    }
}

// MARK: - Shelf Item Card

struct ShelfItemCard: View {
    @EnvironmentObject var client: SyncClient
    let item: RemoteItem
    var open: (URL) -> Void

    var body: some View {
        let localURL = client.localURL(for: item)
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(red: 0.94, green: 0.90, blue: 0.83))
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color(red: 0.28, green: 0.23, blue: 0.20))
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file) + (item.isFolder ? " · folder (zip)" : ""))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.47))
                if let message = client.failures[item.id] {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 4)
            trailing(localURL)
        }
        .padding(10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .onTapGesture {
            if let localURL { open(localURL) } else { Task { await client.download(item) } }
        }
        .contextMenu {
            if localURL != nil {
                ShareLink(item: localURL!) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { client.removeLocal(item) } label: { Label("Remove download", systemImage: "trash") }
            } else {
                Button { Task { await client.download(item) } } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
    }

    @ViewBuilder
    private func trailing(_ localURL: URL?) -> some View {
        if let progress = client.progress[item.id] {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .padding(.trailing, 5)
        } else if let localURL {
            HStack(spacing: 13) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                ShareLink(item: localURL) {
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.17))
                }
                .buttonStyle(.plain)
                Button { client.removeLocal(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.035), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button { Task { await client.download(item) } } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private var icon: String {
        if item.isFolder { return "folder.fill" }
        switch (item.name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav", "aac", "flac": return "waveform"
        case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
        case "txt", "md", "rtf": return "doc.text"
        default: return "doc"
        }
    }
}
