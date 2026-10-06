import Foundation
import UniformTypeIdentifiers
import AVFoundation
import ImageIO

// Model untuk asset yang kompatibel dengan industry apps
struct MediaAsset: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    var fileName: String
    let fileType: AssetType
    var duration: Double
    let originalApp: String // Premiere, After Effects, DaVinci, FCP
    var hasAudio = false
    var naturalSize: CGSize = .zero

    // Media management
    var proxyURL: URL?
    var keywords: [String] = []
    var rating = 0                 // 1 favorit, −1 ditolak, 0 belum dinilai
    var notes = ""
    var frameRate = 0.0
    var codec = ""
    var audioChannels = 0
    var audioSampleRate = 0.0
    var fileSize: Int64 = 0
    var creationDate: Date?

    /// URL yang dipakai saat memutar: proxy bila diminta dan tersedia.
    func playbackURL(useProxy: Bool) -> URL {
        if useProxy, fileType == .video, let proxyURL, FileManager.default.fileExists(atPath: proxyURL.path) { return proxyURL }
        return url
    }

    init(url: URL, fileName: String, fileType: AssetType, duration: Double, originalApp: String,
         hasAudio: Bool = false, naturalSize: CGSize = .zero) {
        self.url = url
        self.fileName = fileName
        self.fileType = fileType
        self.duration = duration
        self.originalApp = originalApp
        self.hasAudio = hasAudio
        self.naturalSize = naturalSize
    }

    // Lokasi file disimpan sebagai path dan, bila bisa, security-scoped bookmark agar tetap terbuka di sandbox.
    private enum CodingKeys: String, CodingKey {
        case id, path, bookmark, fileName, fileType, duration, originalApp, hasAudio, naturalSize
        case proxyPath, keywords, rating, notes, frameRate, codec, audioChannels, audioSampleRate, fileSize, creationDate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url.path, forKey: .path)
        if fileType != .compound, fileType != .multicam, fileType != .adjustment,
           let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            try c.encode(data, forKey: .bookmark)
        }
        try c.encode(fileName, forKey: .fileName)
        try c.encode(fileType, forKey: .fileType)
        try c.encode(duration, forKey: .duration)
        try c.encode(originalApp, forKey: .originalApp)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encode(naturalSize, forKey: .naturalSize)
        try c.encodeIfPresent(proxyURL?.path, forKey: .proxyPath)
        try c.encode(keywords, forKey: .keywords)
        try c.encode(rating, forKey: .rating)
        try c.encode(notes, forKey: .notes)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(codec, forKey: .codec)
        try c.encode(audioChannels, forKey: .audioChannels)
        try c.encode(audioSampleRate, forKey: .audioSampleRate)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encodeIfPresent(creationDate, forKey: .creationDate)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let path = try c.decode(String.self, forKey: .path)
        var resolved = URL(fileURLWithPath: path)
        if let data = try c.decodeIfPresent(Data.self, forKey: .bookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                resolved = url
            }
        }
        url = resolved
        fileName = try c.decode(String.self, forKey: .fileName)
        fileType = try c.decode(AssetType.self, forKey: .fileType)
        duration = try c.decode(Double.self, forKey: .duration)
        originalApp = try c.decode(String.self, forKey: .originalApp)
        hasAudio = try c.decode(Bool.self, forKey: .hasAudio)
        naturalSize = try c.decode(CGSize.self, forKey: .naturalSize)
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyPath).map { URL(fileURLWithPath: $0) }
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? 0
        codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? ""
        audioChannels = try c.decodeIfPresent(Int.self, forKey: .audioChannels) ?? 0
        audioSampleRate = try c.decodeIfPresent(Double.self, forKey: .audioSampleRate) ?? 0
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
    }

    static func == (lhs: MediaAsset, rhs: MediaAsset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// File tidak ada / tidak bisa diakses (mis. media dari FCPXML yang belum di-relink).
    var isOffline: Bool { !FileManager.default.isReadableFile(atPath: url.path) }

    /// Media visual, gambar diam, dan audio bisa dipakai di timeline.
    var isEditable: Bool { fileType == .video || fileType == .image || fileType == .audio }

    /// Aset buatan untuk compound clip dan multicam; isinya ada di TimelineClip, bukan di file.
    static func container(name: String, type: AssetType, duration: Double) -> MediaAsset {
        MediaAsset(url: URL(fileURLWithPath: "/dev/null"), fileName: name, fileType: type,
                   duration: duration, originalApp: "KHCutPro", hasAudio: type != .adjustment)
    }

    enum AssetType: String, Codable {
        case video, audio, image, lut, mogrt, xmlTimeline, compound, multicam, title, adjustment, unknown

        var systemIcon: String {
            switch self {
            case .video: return "film"
            case .audio: return "waveform"
            case .image: return "photo"
            case .lut: return "paintpalette"
            case .mogrt: return "wand.and.stars"
            case .xmlTimeline: return "list.bullet.indent"
            case .compound: return "square.stack.3d.down.right"
            case .multicam: return "rectangle.split.2x2"
            case .title: return "textformat"
            case .adjustment: return "slider.horizontal.3"
            case .unknown: return "doc"
            }
        }
    }
}

struct ImportedTimeline {
    var assets: [MediaAsset] = []
    var clips: [TimelineClip] = []
    var offlineCount = 0
}

enum TimelineImportError: LocalizedError {
    case unsupported(String)
    case invalid

    var errorDescription: String? {
        switch self {
        case .unsupported(let what):
            return "\(what) belum didukung. Format yang bisa diimpor: FCPXML, Premiere XML (Final Cut Pro 7 XML), dan EDL. Untuk project native, ekspor dulu ke salah satu format tersebut."
        case .invalid:
            return "File XML tidak bisa dibaca atau tidak berisi timeline."
        }
    }
}

class AssetCompatibilityService {
    // Format yang didukung dari 4 app besar
    static let supportedExtensions: [String: String] = [
        // Video codecs umum industry
        "mp4": "Premiere / DaVinci / FCP",
        "mov": "All Apps - ProRes",
        "mxf": "Premiere / DaVinci / Broadcast",
        "avi": "Premiere / After Effects",
        "m4v": "FCP / Premiere",

        // Audio
        "wav": "All Apps",
        "aiff": "FCP / Premiere",
        "mp3": "All Apps",
        "aac": "All Apps",
        "m4a": "All Apps",

        // Image & Sequence
        "png": "All Apps",
        "jpg": "All Apps",
        "jpeg": "All Apps",
        "tiff": "DaVinci / FCP",
        "dpx": "DaVinci / Resolve",
        "exr": "After Effects / DaVinci",

        // Timeline Interchange
        "xml": "FCPXML / Premiere XML",
        "fcpxml": "Final Cut Pro",
        "edl": "DaVinci / Premiere / FCP",
        "aaf": "Premiere / DaVinci / Avid",

        // Motion Graphics & LUT
        "mogrt": "Premiere / After Effects",
        "cube": "DaVinci / Premiere / FCP LUT",
        "look": "DaVinci",
        "prproj": "Premiere Project (via XML export)",
        "aep": "After Effects (rendered output)"
    ]

    static let allowedContentTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .quickTimeMovie,
        .audio, .wav, .mp3, .aiff,
        .image, .png, .jpeg, .tiff,
        UTType(filenameExtension: "xml")!,
        UTType(filenameExtension: "fcpxml")!,
        UTType(filenameExtension: "edl")!,
        UTType(filenameExtension: "aaf")!,
        UTType(filenameExtension: "cube")!,
        UTType(filenameExtension: "mogrt")!,
        UTType(filenameExtension: "mxf")!,
        UTType(filenameExtension: "dpx")!,
        UTType(filenameExtension: "exr")!
    ]

    func identifyAsset(url: URL) async -> MediaAsset {
        let ext = url.pathExtension.lowercased()
        let origin = Self.supportedExtensions[ext] ?? "Generic"

        var type: MediaAsset.AssetType
        switch ext {
        case "mp4", "mov", "mxf", "avi", "m4v": type = .video
        case "wav", "aiff", "mp3", "aac", "m4a": type = .audio
        case "png", "jpg", "jpeg", "tiff", "dpx", "exr": type = .image
        case "cube", "look": type = .lut
        case "mogrt": type = .mogrt
        case "xml", "fcpxml", "edl", "aaf", "prproj", "drp": type = .xmlTimeline
        default: type = .unknown
        }

        var duration = 0.0
        var hasAudio = false
        var size = CGSize.zero
        var fps = 0.0
        var codec = ""
        var channels = 0
        var sampleRate = 0.0

        if type == .video || type == .audio {
            let av = AVURLAsset(url: url)
            if let d = try? await av.load(.duration), d.isNumeric { duration = d.seconds }
            let audioTracks = (try? await av.loadTracks(withMediaType: .audio)) ?? []
            hasAudio = !audioTracks.isEmpty
            if let a = audioTracks.first, let d = (try? await a.load(.formatDescriptions))?.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
                channels = Int(asbd.mChannelsPerFrame)
                sampleRate = asbd.mSampleRate
                if type == .audio { codec = Self.fourCC(CMFormatDescriptionGetMediaSubType(d)) }
            }
            if type == .video {
                if let track = (try? await av.loadTracks(withMediaType: .video))?.first,
                   let info = try? await track.load(.naturalSize, .preferredTransform) {
                    let r = CGRect(origin: .zero, size: info.0).applying(info.1)
                    size = CGSize(width: abs(r.width), height: abs(r.height))
                    fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
                    if let d = (try? await track.load(.formatDescriptions))?.first {
                        codec = Self.fourCC(CMFormatDescriptionGetMediaSubType(d))
                    }
                } else {
                    type = hasAudio ? .audio : .unknown // .mov tanpa track video
                }
            }
        }
        if type == .image,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            size = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }

        var asset = MediaAsset(url: url, fileName: url.lastPathComponent, fileType: type, duration: duration,
                               originalApp: origin, hasAudio: hasAudio, naturalSize: size)
        asset.frameRate = fps
        asset.codec = codec
        asset.audioChannels = channels
        asset.audioSampleRate = sampleRate
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        asset.fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        asset.creationDate = attributes?[.creationDate] as? Date
        return asset
    }

    static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)],
               encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }

    // MARK: - Timeline import (FCPXML, Premiere XML, EDL)

    func importTimeline(url: URL) async throws -> ImportedTimeline {
        let ext = url.pathExtension.lowercased()
        let baseDir = url.deletingLastPathComponent()

        switch ext {
        case "edl":
            let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            let items = EDLParser.parse(text)
            guard !items.isEmpty else { throw TimelineImportError.invalid }
            return await assemble(items)

        case "xml", "fcpxml":
            let data = try Data(contentsOf: url)
            let fcp = FCPXMLParser()
            guard fcp.parse(data) else { throw TimelineImportError.invalid }
            switch fcp.rootName {
            case "fcpxml":
                let items: [ImportItem] = fcp.items.compactMap { item in
                    guard let res = fcp.assets[item.ref], let src = res.src else { return nil }
                    let mediaURL = URL(string: src).flatMap { $0.scheme == nil ? nil : $0 }
                        ?? URL(fileURLWithPath: src, relativeTo: baseDir).standardizedFileURL
                    return ImportItem(key: item.ref, url: mediaURL, name: mediaURL.lastPathComponent,
                                      mediaDuration: res.duration, timelineStart: item.timelineStart,
                                      sourceIn: item.start - res.start, duration: item.duration,
                                      lane: item.lane, audioOnly: false)
                }
                guard !items.isEmpty else { throw TimelineImportError.invalid }
                return await assemble(items)
            case "xmeml":
                let xmeml = XMEMLParser()
                guard xmeml.parse(data), !xmeml.items.isEmpty else { throw TimelineImportError.invalid }
                return await assemble(xmeml.items)
            default:
                throw TimelineImportError.invalid
            }

        default:
            throw TimelineImportError.unsupported(ext.uppercased())
        }
    }

    /// Mengubah daftar item hasil parser menjadi asset + klip timeline; media yang tidak terbaca ditandai offline.
    private func assemble(_ items: [ImportItem]) async -> ImportedTimeline {
        var result = ImportedTimeline()
        var mediaByKey: [String: MediaAsset] = [:]

        for item in items {
            let media: MediaAsset
            if let cached = mediaByKey[item.key] {
                media = cached
            } else {
                var m = await identifyAsset(url: item.url)
                if m.isOffline {
                    m = MediaAsset(url: item.url, fileName: item.url.lastPathComponent,
                                   fileType: item.audioOnly ? .audio : .video,
                                   duration: item.mediaDuration, originalApp: "Imported timeline")
                    result.offlineCount += 1
                }
                mediaByKey[item.key] = m
                result.assets.append(m)
                media = m
            }

            let lane = item.lane == 0 ? 0 : (media.fileType == .audio ? -abs(item.lane) : abs(item.lane))
            result.clips.append(TimelineClip(
                asset: media,
                startTime: max(0, item.timelineStart),
                duration: max(0.1, item.duration),
                lane: lane,
                offsetInAsset: max(0, item.sourceIn)
            ))
        }
        return result
    }
}

/// Representasi netral satu klip di timeline sumber, dipakai semua parser.
struct ImportItem {
    var key: String            // identitas media (satu media bisa dipakai banyak klip)
    var url: URL
    var name: String
    var mediaDuration: Double
    var timelineStart: Double
    var sourceIn: Double
    var duration: Double
    var lane: Int
    var audioOnly: Bool
}

// MARK: - EDL (CMX3600)

enum EDLParser {
    static func timecode(_ s: String, fps: Double) -> Double? {
        let p = s.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return p[0] * 3600 + p[1] * 60 + p[2] + p[3] / fps
    }

    private struct Event {
        var reel: String; var isVideo: Bool
        var srcIn: Double; var recIn: Double; var recOut: Double
        var name: String?; var path: String?
    }

    /// Frame rate EDL tidak tercatat di file, jadi diasumsikan sama dengan proyek (30 fps).
    static func parse(_ text: String, fps: Double = projectFrameRate) -> [ImportItem] {
        var events: [Event] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") {
                let upper = line.uppercased()
                guard !events.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if upper.contains("FROM CLIP NAME") || upper.hasPrefix("* CLIP NAME") { events[events.count - 1].name = value }
                else if upper.contains("SOURCE FILE") { events[events.count - 1].path = value }
                continue
            }
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 8, t[0].allSatisfy(\.isNumber),
                  let srcIn = timecode(t[t.count - 4], fps: fps),
                  let recIn = timecode(t[t.count - 2], fps: fps),
                  let recOut = timecode(t[t.count - 1], fps: fps), recOut > recIn else { continue }
            let track = t[2].uppercased()
            events.append(Event(reel: t[1], isVideo: track.contains("V") || track == "B",
                                srcIn: srcIn, recIn: recIn, recOut: recOut))
        }

        let origin = events.map(\.recIn).min() ?? 0
        var items: [ImportItem] = []
        for e in events where e.reel.uppercased() != "BL" {
            let name = e.name ?? e.reel
            let start = e.recIn - origin, duration = e.recOut - e.recIn
            if !e.isVideo, items.contains(where: { $0.key == name && abs($0.timelineStart - start) < 0.001 && abs($0.duration - duration) < 0.001 }) {
                continue // audio tertaut ke video yang sama; audionya ikut diputar bersama klip video
            }
            let url = e.path.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/Offline/\(name)")
            // Media dengan timecode awal 01:00:00:00 umum dipakai, sedangkan file-nya mulai dari 0.
            let srcIn = e.srcIn >= 3600 ? e.srcIn.truncatingRemainder(dividingBy: 3600) : e.srcIn
            items.append(ImportItem(key: name, url: url, name: name, mediaDuration: 0, timelineStart: start,
                                    sourceIn: srcIn, duration: duration, lane: e.isVideo ? 0 : -1, audioOnly: !e.isVideo))
        }
        return items
    }
}

// MARK: - Premiere XML (xmeml)

final class XMEMLParser: NSObject, XMLParserDelegate {
    private struct File { var name = ""; var url: URL?; var duration = 0.0; var fps = 0.0 }
    private struct Entry {
        var kind: String; var track: Int; var fileID = ""; var name = ""
        var start = 0.0, end = 0.0, inPoint = 0.0, outPoint = 0.0, fps = 0.0
        var enabled = true
    }

    private(set) var items: [ImportItem] = []

    private var stack: [String] = []
    private var text = ""
    private var sequenceDepth = 0
    private var sequenceFPS = 30.0
    private var sequenceFPSSet = false
    private var inTimelineMedia = false
    private var kind = ""
    private var trackIndex = 0
    private var clip: Entry?
    private var files: [String: File] = [:]
    private var fileID: String?
    private var timebase = 0.0
    private var ntsc = false
    private var entries: [Entry] = []

    func parse(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse()
    }

    private static func mediaURL(_ value: String) -> URL {
        var path = value
        for prefix in ["file://localhost", "file://"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
            break
        }
        return URL(fileURLWithPath: path.removingPercentEncoding ?? path)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        let parent = stack.last ?? ""
        text = ""
        if name == "sequence" {
            sequenceDepth += 1
        } else if name == "media", parent == "sequence", sequenceDepth == 1 {
            inTimelineMedia = true
        } else if inTimelineMedia, clip == nil, (name == "video" || name == "audio"), parent == "media" {
            kind = name
            trackIndex = 0
        } else if inTimelineMedia, clip == nil, name == "track", parent == kind {
            trackIndex += 1
        } else if inTimelineMedia, sequenceDepth == 1, name == "clipitem", parent == "track" {
            clip = Entry(kind: kind, track: trackIndex)
        } else if name == "file", clip != nil, parent == "clipitem" {
            fileID = a["id"]
            clip?.fileID = a["id"] ?? ""
            if let id = a["id"], files[id] == nil { files[id] = File() }
        }
        stack.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if !stack.isEmpty { stack.removeLast() }
        let parent = stack.last ?? ""
        let number = Double(value) ?? 0

        switch name {
        case "timebase": timebase = number
        case "ntsc": ntsc = value.uppercased() == "TRUE"
        case "rate":
            let fps = timebase > 0 ? timebase * (ntsc ? 1000.0 / 1001.0 : 1) : 0
            if parent == "sequence", sequenceDepth == 1, !sequenceFPSSet, fps > 0 {
                sequenceFPS = fps
                sequenceFPSSet = true
            } else if parent == "clipitem" {
                clip?.fps = fps
            } else if parent == "file", let id = fileID {
                files[id]?.fps = fps
            }
            timebase = 0
            ntsc = false
        case "name":
            if parent == "clipitem" { clip?.name = value }
            else if parent == "file", let id = fileID { files[id]?.name = value }
        case "pathurl":
            if parent == "file", let id = fileID { files[id]?.url = Self.mediaURL(value) }
        case "start": if parent == "clipitem" { clip?.start = number }
        case "end": if parent == "clipitem" { clip?.end = number }
        case "in": if parent == "clipitem" { clip?.inPoint = number }
        case "out": if parent == "clipitem" { clip?.outPoint = number }
        case "duration": if parent == "file", let id = fileID { files[id]?.duration = number }
        case "enabled": if parent == "clipitem" { clip?.enabled = value.uppercased() != "FALSE" }
        case "file": if parent == "clipitem" { fileID = nil }
        case "clipitem":
            if parent == "track", let c = clip {
                entries.append(c)
                clip = nil
            }
        case "media": if parent == "sequence" { inTimelineMedia = false }
        case "sequence": sequenceDepth -= 1
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        // Audio yang tertaut ke klip video memakai file yang sama; audionya sudah ikut diputar bersama videonya.
        let videoFiles = Set(entries.filter { $0.kind == "video" }.map(\.fileID))
        var seenAudio = Set<String>()

        for e in entries where e.enabled {
            guard let file = files[e.fileID], let url = file.url else { continue }
            if e.kind == "audio" {
                if videoFiles.contains(e.fileID) { continue }
                // Stereo disimpan sebagai dua track mono yang identik; cukup satu.
                if !seenAudio.insert("\(e.fileID)|\(e.start)|\(e.end)|\(e.inPoint)").inserted { continue }
            }
            let clipFPS = e.fps > 0 ? e.fps : (file.fps > 0 ? file.fps : sequenceFPS)
            let hasPosition = e.start >= 0 && e.end > e.start
            let duration = hasPosition ? (e.end - e.start) / sequenceFPS : (e.outPoint - e.inPoint) / clipFPS
            guard duration > 0 else { continue }
            items.append(ImportItem(
                key: e.fileID, url: url, name: file.name.isEmpty ? url.lastPathComponent : file.name,
                mediaDuration: file.fps > 0 ? file.duration / file.fps : 0,
                timelineStart: max(0, e.start) / sequenceFPS, sourceIn: e.inPoint / clipFPS, duration: duration,
                lane: e.kind == "video" ? e.track - 1 : -e.track, audioOnly: e.kind == "audio"))
        }
    }
}

// MARK: - FCPXML parser

/// Membaca <asset> / <asset-clip> dari sequence pertama. Offset klip yang terhubung
/// (connected clip) dihitung relatif terhadap klip induknya, sesuai spesifikasi FCPXML.
final class FCPXMLParser: NSObject, XMLParserDelegate {
    struct Resource { var id: String; var src: String?; var start: Double; var duration: Double }
    struct Item { var ref: String; var timelineStart: Double; var start: Double; var duration: Double; var lane: Int }
    private struct Frame { var timelineStart: Double; var start: Double }

    private(set) var rootName = ""
    private(set) var assets: [String: Resource] = [:]
    private(set) var items: [Item] = []

    private var stack: [Frame] = [Frame(timelineStart: 0, start: 0)]
    private var currentAsset: String?
    private var sequenceCount = 0
    private var sequenceDepth = 0

    func parse(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse()
    }

    static func seconds(_ raw: String?) -> Double {
        guard var s = raw, !s.isEmpty else { return 0 }
        if s.hasSuffix("s") { s.removeLast() }
        if let slash = s.firstIndex(of: "/"),
           let n = Double(s[..<slash]), let d = Double(s[s.index(after: slash)...]), d != 0 {
            return n / d
        }
        return Double(s) ?? 0
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        if rootName.isEmpty { rootName = name }
        var frame = stack.last!

        switch name {
        case "asset":
            if let id = a["id"] {
                assets[id] = Resource(id: id, src: a["src"], start: Self.seconds(a["start"]),
                                      duration: Self.seconds(a["duration"]))
                currentAsset = id
            }
        case "media-rep":
            if let id = currentAsset, assets[id]?.src == nil { assets[id]?.src = a["src"] }
        case "sequence":
            sequenceCount += 1
            sequenceDepth += 1
            frame = Frame(timelineStart: 0, start: Self.seconds(a["tcStart"]))
        case "asset-clip", "video", "audio", "clip", "gap", "sync-clip", "ref-clip":
            let parent = stack.last!
            let start = Self.seconds(a["start"])
            let ts = parent.timelineStart + (Self.seconds(a["offset"]) - parent.start)
            if sequenceDepth > 0, sequenceCount == 1, let ref = a["ref"], assets[ref] != nil,
               name == "asset-clip" || name == "video" || name == "audio" {
                items.append(Item(ref: ref, timelineStart: ts, start: start,
                                  duration: Self.seconds(a["duration"]), lane: Int(a["lane"] ?? "") ?? 0))
            }
            frame = Frame(timelineStart: ts, start: start)
        default:
            break
        }
        stack.append(frame)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "asset" { currentAsset = nil }
        if name == "sequence" { sequenceDepth -= 1 }
        if stack.count > 1 { stack.removeLast() }
    }
}
