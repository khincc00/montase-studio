import AppKit
import UniformTypeIdentifiers

/// Isi file project `.khcutpro` (JSON).
struct ProjectFile: Codable {
    var version = 1
    var name: String
    var assets: [MediaAsset]
    var clips: [TimelineClip]
    var snapshots: [Snapshot]
    var markIn: Double?
    var markOut: Double?
    var roleMix: [AudioRole: RoleMix]?
    var smartCollections: [SmartCollection]?
    var markers: [TimelineMarker]?
    var colorManagement: ColorManagementMode?
    var frameRate: Double?
}

enum ProjectError: LocalizedError {
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .newerVersion(let v): "Project dibuat dengan versi file \(v) yang lebih baru dari yang didukung app ini."
        }
    }
}

enum ProjectIO {
    static let fileExtension = "khcutpro"
    static var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .json }

    @MainActor
    static func encode(timeline: TimelineModel, library: MediaLibrary) throws -> Data {
        let file = ProjectFile(name: library.projectName, assets: library.assets, clips: timeline.rootClips,
                               snapshots: timeline.snapshots, markIn: timeline.markIn, markOut: timeline.markOut,
                               roleMix: timeline.roleMix, smartCollections: library.smartCollections, markers: timeline.markers,
                               colorManagement: timeline.colorManagement, frameRate: timeline.frameRate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    @MainActor
    static func apply(_ data: Data, timeline: TimelineModel, library: MediaLibrary) throws {
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        guard file.version <= 1 else { throw ProjectError.newerVersion(file.version) }
        library.replaceAssets(file.assets, name: file.name)
        timeline.replaceProject(clips: file.clips, snapshots: file.snapshots, markIn: file.markIn, markOut: file.markOut)
        timeline.roleMix = file.roleMix ?? [:]
        library.smartCollections = file.smartCollections ?? []
        timeline.markers = file.markers ?? []
        timeline.colorManagement = file.colorManagement ?? .off
        timeline.setFrameRate(file.frameRate ?? 30)
    }
}

@MainActor
extension MediaLibrary {
    func replaceAssets(_ newAssets: [MediaAsset], name: String) {
        assets = newAssets
        thumbnails = [:]
        selectedAssetID = nil
        selectedAssetIDs = []
        projectName = name
    }

    func saveProject(timeline: TimelineModel, saveAs: Bool = false) {
        var target = projectURL
        if saveAs || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [ProjectIO.contentType]
            panel.nameFieldStringValue = "\(projectName).\(ProjectIO.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
            projectName = url.deletingPathExtension().lastPathComponent
        }
        guard let url = target else { return }
        do {
            try ProjectIO.encode(timeline: timeline, library: self).write(to: url, options: .atomic)
            projectURL = url
        } catch {
            alertMessage = "Gagal menyimpan project: \(error.localizedDescription)"
        }
    }

    func openProject(timeline: TimelineModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectIO.contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectIO.apply(try Data(contentsOf: url), timeline: timeline, library: self)
            projectURL = url
            projectName = url.deletingPathExtension().lastPathComponent
        } catch {
            alertMessage = "Gagal membuka project: \(error.localizedDescription)"
        }
    }
}
