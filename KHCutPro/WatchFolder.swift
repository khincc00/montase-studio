import AppKit

extension MediaLibrary {
    private static let watchedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mxf", "avi", "wav", "aiff", "aif", "mp3", "aac", "m4a", "png", "jpg", "jpeg", "tiff"
    ]

    /// Pilih folder yang dipantau; media baru yang masuk ke folder itu otomatis diimpor ke Browser.
    func chooseWatchFolder(timeline: TimelineModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Pantau Folder"
        panel.message = "Media baru di folder ini akan otomatis diimpor"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        startWatching(folder, timeline: timeline)
    }

    func startWatching(_ folder: URL, timeline: TimelineModel, interval: Duration = .seconds(2)) {
        stopWatching()
        _ = folder.startAccessingSecurityScopedResource()
        watchedFolder = folder
        // File yang sudah ada saat mulai tidak diimpor; hanya yang baru.
        var known = Set(Self.listMedia(in: folder))
        watchTask = Task { [weak self] in
            var pending: [URL: Int64] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                for url in Self.listMedia(in: folder) where !known.contains(url) {
                    // File dianggap selesai disalin bila ukurannya tidak berubah antara dua pemeriksaan.
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if let last = pending[url], last == size, size > 0 {
                        known.insert(url)
                        pending[url] = nil
                        await self.importFiles([url], into: timeline)
                        self.watchedImportCount += 1
                    } else {
                        pending[url] = size
                    }
                }
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        if let folder = watchedFolder { folder.stopAccessingSecurityScopedResource() }
        watchedFolder = nil
    }

    private static func listMedia(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { watchedExtensions.contains($0.pathExtension.lowercased()) }
    }
}
