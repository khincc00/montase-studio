import SwiftUI

/// Pencarian, filter, smart collection, dan kontrol proxy di atas Browser.
struct BrowserToolbar: View {
    @Environment(MediaLibrary.self) private var library
    @Environment(TimelineModel.self) private var timeline
    @State private var showSave = false
    @State private var collectionName = ""

    private var filterTitle: String {
        switch library.activeFilter {
        case .all: "Semua Media"
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Gambar"
        case .favorites: "Favorit"
        case .rejected: "Ditolak"
        case .offline: "Offline"
        case .noKeywords: "Tanpa Keyword"
        case .noProxy: "Tanpa Proxy"
        case .collection(let id): library.smartCollections.first { $0.id == id }?.name ?? "Smart Collection"
        }
    }

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(FCP.secondary)
                TextField("Cari nama, keyword, catatan", text: $library.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !library.searchText.isEmpty {
                    Button { library.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(FCP.secondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 3) {
                quickFilterButton(title: "Semua", filter: .all)
                quickFilterButton(title: "Video", icon: "film", filter: .video)
                quickFilterButton(title: "Audio", icon: "waveform", filter: .audio)
                quickFilterButton(title: "Gambar", icon: "photo", filter: .image)
                quickFilterButton(title: "Favorit", icon: "star.fill", filter: .favorites)

                Menu {
                    Button("Ditolak") { library.activeFilter = .rejected }
                    Button("Offline") { library.activeFilter = .offline }
                    Button("Tanpa Keyword") { library.activeFilter = .noKeywords }
                    Button("Tanpa Proxy") { library.activeFilter = .noProxy }
                    if !library.smartCollections.isEmpty {
                        Divider()
                        ForEach(library.smartCollections) { c in
                            Button(c.name) { library.activeFilter = .collection(c.id) }
                        }
                    }
                    if !library.allKeywords.isEmpty {
                        Divider()
                        Menu("Keyword") {
                            ForEach(library.allKeywords, id: \.self) { k in Button(k) { library.searchText = k } }
                        }
                    }
                    Divider()
                    Button("Simpan Filter Ini sebagai Smart Collection…") { collectionName = ""; showSave = true }
                    if case .collection(let id) = library.activeFilter {
                        Button("Hapus Smart Collection Ini", role: .destructive) {
                            library.smartCollections.removeAll { $0.id == id }
                            library.activeFilter = .all
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 8.5))
                        if isSecondaryFilterActive {
                            Circle().fill(FCP.selection).frame(width: 4, height: 4)
                        }
                    }
                    .frame(width: 22, height: 20)
                    .background(isSecondaryFilterActive ? FCP.selection.opacity(0.2) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(filterTitle)

                Spacer()

                Toggle("Proxy", isOn: Binding(get: { timeline.useProxies }, set: { timeline.setUseProxies($0) }))
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Edit memakai proxy ringan; export tetap memakai file asli")

                Menu {
                    Button("Buat Proxy untuk Semua Video") { Task { await library.generateAllProxies(timeline: timeline) } }
                    Toggle("Proxy otomatis untuk media 4K+", isOn: $library.autoProxy)
                    Divider()
                    if let folder = library.watchedFolder {
                        Button("Berhenti Memantau “\(folder.lastPathComponent)”") { library.stopWatching() }
                    } else {
                        Button("Pantau Folder (Watch Folder)…") { library.chooseWatchFolder(timeline: timeline) }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)) }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let folder = library.watchedFolder {
                HStack(spacing: 6) {
                    Image(systemName: "eye").font(.system(size: 9))
                    Text("Memantau: \(folder.lastPathComponent) • \(library.watchedImportCount) diimpor")
                        .font(.system(size: 9)).foregroundStyle(FCP.secondary)
                    Spacer()
                }
            }
            if !library.proxyStatus.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(library.proxyStatus).font(.system(size: 9)).foregroundStyle(FCP.secondary) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(FCP.panel)
        .alert("Smart Collection Baru", isPresented: $showSave) {
            TextField("Nama", text: $collectionName)
            Button("Simpan") { library.saveSmartCollection(named: collectionName, criteria: library.currentCriteria) }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Koleksi otomatis menampilkan media yang cocok dengan filter dan pencarian saat ini.")
        }
    }

    private var isSecondaryFilterActive: Bool {
        switch library.activeFilter {
        case .all, .video, .audio, .image, .favorites:
            return false
        default:
            return true
        }
    }

    private func quickFilterButton(title: String, icon: String? = nil, filter: LibraryFilter) -> some View {
        let isActive = library.activeFilter == filter
        return Button {
            library.activeFilter = filter
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                }
                Text(title)
                    .font(.system(size: 9.5, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 5)
            .frame(height: 20)
            .background(isActive ? FCP.selection.opacity(0.22) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isActive ? FCP.selection.opacity(0.6) : Color.clear, lineWidth: 1))
            .foregroundStyle(isActive ? FCP.selection : FCP.secondary)
        }
        .buttonStyle(.plain)
        .help("Filter media: \(title)")
    }
}

/// Keyword, rating, catatan, metadata, dan proxy untuk media terpilih di Browser.
struct AssetMetadataSection: View {
    @Environment(MediaLibrary.self) private var library
    @Environment(TimelineModel.self) private var timeline
    let asset: MediaAsset
    @State private var keywordText = ""
    @State private var loadedID: UUID?

    private var current: MediaAsset { library.assets.first { $0.id == asset.id } ?? asset }

    var body: some View {
        InspectorSection(title: "Organisasi") {
            HStack(spacing: 8) {
                Button { library.toggleFavorite(asset.id) } label: {
                    Label("Favorit", systemImage: current.rating > 0 ? "star.fill" : "star")
                }
                .tint(current.rating > 0 ? FCP.selection : nil)
                Button { library.toggleRejected(asset.id) } label: {
                    Label("Tolak", systemImage: current.rating < 0 ? "xmark.circle.fill" : "xmark.circle")
                }
                .tint(current.rating < 0 ? .red : nil)
            }
            .buttonStyle(.bordered).controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text("Keyword (pisahkan dengan koma)").font(.system(size: 10)).foregroundStyle(FCP.secondary)
                TextField("mis. wawancara, kota, malam", text: $keywordText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { library.setKeywords(asset.id, from: keywordText) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Catatan").font(.system(size: 10)).foregroundStyle(FCP.secondary)
                TextEditor(text: Binding(get: { current.notes }, set: { v in library.updateAsset(asset.id) { $0.notes = v } }))
                    .font(.system(size: 11))
                    .frame(height: 50)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .onAppear { sync() }
        .onChange(of: asset.id) { sync() }

        InspectorSection(title: "Metadata") {
            row("Codec", current.codec.isEmpty ? "—" : current.codec)
            if current.fileType == .video {
                row("Resolusi", "\(Int(current.naturalSize.width)) × \(Int(current.naturalSize.height))")
                row("Frame rate", current.frameRate > 0 ? String(format: "%.2f fps", current.frameRate) : "—")
            }
            if current.hasAudio || current.fileType == .audio {
                row("Audio", "\(current.audioChannels) ch • \(Int(current.audioSampleRate)) Hz")
            }
            row("Ukuran file", ByteCountFormatter.string(fromByteCount: current.fileSize, countStyle: .file))
            if let d = current.creationDate { row("Dibuat", d.formatted(date: .abbreviated, time: .shortened)) }
            row("Lokasi", current.url.path)
        }

        if current.fileType == .video {
            InspectorSection(title: "Proxy") {
                HStack {
                    Text(current.proxyURL == nil ? "Belum ada proxy" : "Proxy siap (1280×720)")
                        .font(.system(size: 11))
                        .foregroundStyle(current.proxyURL == nil ? FCP.secondary : .white)
                    Spacer()
                    if current.proxyURL == nil {
                        Button("Buat Proxy") { Task { await library.generateProxy(for: current, timeline: timeline) } }
                    } else {
                        Button("Hapus") { library.removeProxy(for: current, timeline: timeline) }
                    }
                }
                .controlSize(.small)
            }
        }
        if current.isOffline {
            Button("Relink…") { Task { await library.relinkManually(current, timeline: timeline) } }
                .controlSize(.small).padding(10)
        }
    }

    private func sync() {
        if loadedID != asset.id { keywordText = current.keywords.joined(separator: ", "); loadedID = asset.id }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(FCP.secondary).frame(width: 72, alignment: .leading)
            Text(value).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }
}
