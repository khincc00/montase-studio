import AVFoundation
import AppKit

// MARK: - Proxy

enum ProxyGenerator {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KHCutPro/Proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Proxy H.264 720p dengan audio; dipakai saat editing, sedangkan export selalu memakai file asli.
    static func generate(for asset: MediaAsset, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let output = directory.appendingPathComponent("\(asset.id.uuidString).mp4")
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: asset.url), presetName: AVAssetExportPreset1280x720) else {
            throw ExportError.unavailable(.h264720)
        }
        nonisolated(unsafe) let watched = session
        let ticker = Task {
            for await state in watched.states(updateInterval: 0.3) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { ticker.cancel() }
        try await session.export(to: output, as: .mp4)
        return output
    }
}

// MARK: - Library organisation

struct SmartCriteria: Codable, Equatable {
    var text = ""
    var type: MediaAsset.AssetType?
    var keyword = ""
    var minRating: Int?              // 1 = hanya favorit
    var offlineOnly = false
    var minDuration: Double?
    var maxDuration: Double?
    var requireProxy: Bool?
    var minWidth: Double?

    var isEmpty: Bool { self == SmartCriteria() }

    func matches(_ a: MediaAsset) -> Bool {
        if !text.isEmpty {
            let q = text.lowercased()
            let hay = ([a.fileName, a.notes, a.codec] + a.keywords).joined(separator: " ").lowercased()
            if !hay.contains(q) { return false }
        }
        if let type, a.fileType != type { return false }
        if !keyword.isEmpty, !a.keywords.contains(where: { $0.lowercased().contains(keyword.lowercased()) }) { return false }
        if let minRating, a.rating < minRating { return false }
        if offlineOnly, !a.isOffline { return false }
        if let minDuration, a.duration < minDuration { return false }
        if let maxDuration, a.duration > maxDuration { return false }
        if let requireProxy, (a.proxyURL != nil) != requireProxy { return false }
        if let minWidth, a.naturalSize.width < minWidth { return false }
        return true
    }
}

struct SmartCollection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var criteria: SmartCriteria
}

enum LibraryFilter: Hashable {
    case all, video, audio, image, favorites, rejected, offline, noKeywords, noProxy
    case collection(UUID)
}

extension MediaLibrary {
    var filteredAssets: [MediaAsset] {
        var result = assets
        switch activeFilter {
        case .all: break
        case .video: result = result.filter { $0.fileType == .video }
        case .audio: result = result.filter { $0.fileType == .audio }
        case .image: result = result.filter { $0.fileType == .image }
        case .favorites: result = result.filter { $0.rating > 0 }
        case .rejected: result = result.filter { $0.rating < 0 }
        case .offline: result = result.filter(\.isOffline)
        case .noKeywords: result = result.filter { $0.keywords.isEmpty && $0.isEditable }
        case .noProxy: result = result.filter { $0.fileType == .video && $0.proxyURL == nil }
        case .collection(let id):
            if let c = smartCollections.first(where: { $0.id == id }) { result = result.filter { c.criteria.matches($0) } }
        }
        if !searchText.isEmpty {
            var c = SmartCriteria(); c.text = searchText
            result = result.filter { c.matches($0) }
        }
        // Media yang ditolak disembunyikan kecuali filter Ditolak dipilih.
        if activeFilter != .rejected { result = result.filter { $0.rating >= 0 || searchText.isEmpty == false } }
        return result
    }

    func updateAsset(_ id: UUID, _ change: (inout MediaAsset) -> Void) {
        guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
        change(&assets[i])
    }

    func setKeywords(_ id: UUID, from text: String) {
        let words = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        updateAsset(id) { $0.keywords = Array(NSOrderedSet(array: words)) as? [String] ?? words }
    }

    func toggleFavorite(_ id: UUID) { updateAsset(id) { $0.rating = $0.rating > 0 ? 0 : 1 } }
    func toggleRejected(_ id: UUID) { updateAsset(id) { $0.rating = $0.rating < 0 ? 0 : -1 } }

    /// Simpan pencarian + filter aktif sebagai smart collection.
    func saveSmartCollection(named name: String, criteria: SmartCriteria) {
        guard !name.isEmpty else { return }
        smartCollections.append(SmartCollection(name: name, criteria: criteria))
        activeFilter = .collection(smartCollections.last!.id)
        searchText = ""
    }

    /// Kriteria dari filter dan pencarian yang sedang aktif (untuk disimpan sebagai smart collection).
    var currentCriteria: SmartCriteria {
        var c = SmartCriteria()
        c.text = searchText
        switch activeFilter {
        case .video: c.type = .video
        case .audio: c.type = .audio
        case .image: c.type = .image
        case .favorites: c.minRating = 1
        case .offline: c.offlineOnly = true
        case .noProxy: c.type = .video; c.requireProxy = false
        case .collection(let id): if let existing = smartCollections.first(where: { $0.id == id }) { var base = existing.criteria; base.text = searchText.isEmpty ? base.text : searchText; return base }
        default: break
        }
        return c
    }

    var allKeywords: [String] {
        Array(Set(assets.flatMap(\.keywords))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Proxy

    func generateProxy(for asset: MediaAsset, timeline: TimelineModel) async {
        guard asset.fileType == .video, !asset.isOffline else { return }
        proxyStatus = "Membuat proxy: \(asset.fileName)"
        defer { proxyStatus = "" }
        do {
            let url = try await ProxyGenerator.generate(for: asset)
            updateAsset(asset.id) { $0.proxyURL = url }
            if let updated = assets.first(where: { $0.id == asset.id }) { timeline.replaceAsset(updated) }
        } catch {
            alertMessage = "Proxy untuk \(asset.fileName) gagal: \(error.localizedDescription)"
        }
    }

    func generateAllProxies(timeline: TimelineModel) async {
        for a in assets where a.fileType == .video && a.proxyURL == nil { await generateProxy(for: a, timeline: timeline) }
    }

    func removeProxy(for asset: MediaAsset, timeline: TimelineModel) {
        if let url = asset.proxyURL { try? FileManager.default.removeItem(at: url) }
        updateAsset(asset.id) { $0.proxyURL = nil }
        if let updated = assets.first(where: { $0.id == asset.id }) { timeline.replaceAsset(updated) }
    }

    /// Relink manual: pilih file pengganti untuk media yang offline; keyword dan rating dipertahankan.
    func relinkManually(_ old: MediaAsset, timeline: TimelineModel) async {
        let panel = NSOpenPanel()
        panel.message = "Pilih file pengganti untuk \(old.fileName)"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        var new = await AssetCompatibilityService().identifyAsset(url: url)
        new.keywords = old.keywords; new.rating = old.rating; new.notes = old.notes
        timeline.relink(old, to: new)
        if let i = assets.firstIndex(where: { $0.id == old.id }) { assets[i] = new }
        thumbnails[new.id] = nil
    }
}

// MARK: - Asset replacement inside clips

extension TimelineClip {
    mutating func replaceAsset(_ new: MediaAsset) {
        if asset.id == new.id { asset = new }
        for i in takes.indices where takes[i].asset.id == new.id { takes[i].asset = new }
        for i in children.indices { children[i].replaceAsset(new) }
        if multicam != nil {
            for i in multicam!.angles.indices where multicam!.angles[i].asset.id == new.id { multicam!.angles[i].asset = new }
        }
    }
}

extension TimelineModel {
    func replaceAsset(_ new: MediaAsset) {
        for i in clips.indices { clips[i].replaceAsset(new) }
        replaceAssetInCompoundStack(new)
        scheduleRebuildExternal()
    }

    func setColorManagement(_ mode: ColorManagementMode) {
        guard mode != colorManagement else { return }
        colorManagement = mode
        scheduleRebuildExternal()
    }

    func setUseProxies(_ on: Bool) {
        guard on != useProxies else { return }
        useProxies = on
        scheduleRebuildExternal()
    }
}
