import AppKit
import AVFoundation
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Frame rate project yang bisa dipilih pengguna.
let supportedFrameRates: [Double] = [24, 30, 60]

/// Frame rate project aktif. Hanya diubah lewat `TimelineModel.setFrameRate` di main actor.
nonisolated(unsafe) var projectFrameRate = 30.0

func timecodeString(_ seconds: Double) -> String {
    let fps = Int(projectFrameRate)
    let total = Int((max(0, seconds) * projectFrameRate).rounded())
    return String(format: "%02d:%02d:%02d:%02d", total / (fps * 3600), (total / (fps * 60)) % 60, (total / fps) % 60, total % fps)
}

enum EditTool: String, CaseIterable {
    case select, trim, blade

    var title: String {
        switch self {
        case .select: "Select"
        case .trim: "Trim"
        case .blade: "Blade"
        }
    }
    var icon: String {
        switch self {
        case .select: "arrow.up.left"
        case .trim: "arrow.left.and.right.square"
        case .blade: "scissors"
        }
    }
    var key: String {
        switch self {
        case .select: "A"
        case .trim: "T"
        case .blade: "B"
        }
    }
}

enum TrimMode: String, CaseIterable {
    case ripple, roll, slip, slide

    var title: String { rawValue.capitalized }
    var help: String {
        switch self {
        case .ripple: "Ripple: seret tepi klip, klip sesudahnya ikut bergeser"
        case .roll: "Roll: seret titik potong antara dua klip, durasi total tetap"
        case .slip: "Slip: geser isi klip tanpa mengubah posisi dan durasinya"
        case .slide: "Slide: geser klip, klip di kiri dan kanannya menyesuaikan"
        }
    }
}

enum ClipEdge { case head, tail }

/// Satu pilihan take di dalam audition.
struct Take: Codable {
    var asset: MediaAsset
    var offsetInAsset: Double
}

struct TimelineClip: Identifiable, Codable {
    var id = UUID()
    var asset: MediaAsset
    var startTime: Double      // posisi di timeline (detik)
    var duration: Double
    /// 0 = primary storyline (magnetic), >0 = connected di atas, <0 = audio di bawah
    var lane: Int
    var offsetInAsset: Double = 0
    var scale: Double = 1.0
    var opacity: Double = 1.0
    var positionX: Double = 0
    var positionY: Double = 0
    var volumeDB: Double = 0
    var isMuted = false
    /// Node grading (serial). Selalu minimal satu; `grade` adalah jalan pintas ke node yang sedang dipilih.
    var nodes: [ColorNode] = [ColorNode(name: "Node 1")]
    var activeNode = 0
    var keyer = Keyer()
    var backgroundRemoval: Bool?
    var mask = MaskSpec()
    var inputSpace = InputColorSpace.rec709
    var rotation: Double = 0
    var cropLeft = 0.0
    var cropRight = 0.0
    var cropTop = 0.0
    var cropBottom = 0.0
    var blend: BlendMode = .normal
    var fadeIn = 0.0
    var fadeOut = 0.0
    /// Keyframe per properti (waktu dalam waktu media).
    var tracks: [AnimProperty: KeyframeTrack] = [:]
    /// Kecepatan klip (konstan atau speed ramp). nil = 1×.
    var retime: Retime?

    /// Klip connected menempel pada klip primary ini dan ikut bergeser bersamanya.
    var anchorID: UUID?
    /// Isi compound clip (waktu relatif terhadap awal compound).
    var children: [TimelineClip] = []
    var multicam: MulticamData?
    var takes: [Take] = []
    var activeTake = 0
    var role: AudioRole = .dialogue
    var fx = AudioFX()
    var title: TitleSpec?
    /// Transisi masuk (hanya klip primary). Overlap dihitung ulang oleh reflow.
    var transition: TransitionSpec?
    var transitionOverlap = 0.0
    var transitionOutOverlap = 0.0

    var grade: ColorGrade {
        get { nodes[min(max(activeNode, 0), nodes.count - 1)].grade }
        set { nodes[min(max(activeNode, 0), nodes.count - 1)].grade = newValue }
    }

    var endTime: Double { startTime + duration }
    var isCompound: Bool { asset.fileType == .compound }
    var isAdjustmentLayer: Bool { asset.fileType == .adjustment }
    var isContainer: Bool { isCompound || multicam != nil }
    var isAudition: Bool { takes.count > 1 }

    var displayName: String {
        if let mc = multicam, mc.angles.indices.contains(mc.activeVideo) {
            return "\(asset.fileName) — \(mc.angles[mc.activeVideo].name)"
        }
        return asset.fileName
    }

    /// Media yang dipakai untuk thumbnail klip.
    var thumbnailAssetID: UUID? {
        if let mc = multicam, mc.angles.indices.contains(mc.activeVideo) { return mc.angles[mc.activeVideo].asset.id }
        if isCompound { return children.first?.thumbnailAssetID }
        return asset.id
    }

    /// Anak compound yang terlihat pada jendela [offsetInAsset, offsetInAsset + duration), dengan waktu absolut.
    func windowedChildren() -> [TimelineClip] {
        children.compactMap { child in
            let a = max(child.startTime, offsetInAsset)
            let b = min(child.endTime, offsetInAsset + duration)
            guard b - a > 0.001 else { return nil }
            var c = child
            c.startTime = startTime + (a - offsetInAsset)
            c.trimHead(by: a - child.startTime)
            c.duration = b - a
            c.opacity *= opacity
            c.volumeDB += volumeDB
            c.isMuted = child.isMuted || isMuted
            c.anchorID = nil
            return c
        }
    }
}

/// Klip yang sudah "dibuka" dari compound / multicam menjadi klip media biasa.
struct FlatClip {
    var clip: TimelineClip
    var layer: Int
    var useVideo = true
    var useAudio = true
}

// MARK: - Media library

@MainActor
@Observable
final class MediaLibrary {
    var assets: [MediaAsset] = []
    var selectedAssetID: UUID?
    var selectedAssetIDs: Set<UUID> = []
    var thumbnails: [UUID: NSImage] = [:]
    var filmstrips: [UUID: [NSImage]] = [:]
    var isImporterPresented = false
    var isSyncing = false
    var alertMessage: String?
    var projectURL: URL?
    var projectName = "Untitled"
    var smartCollections: [SmartCollection] = []
    var searchText = ""
    var activeFilter: LibraryFilter = .all
    var proxyStatus = ""
    var autoProxy = true
    var watchedFolder: URL?
    var watchedImportCount = 0
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored private var loadingFilmstrips: Set<UUID> = []

    @ObservationIgnored private let service = AssetCompatibilityService()

    var selectedAsset: MediaAsset? { assets.first { $0.id == selectedAssetID } }

    func selectAsset(_ id: UUID?, extend: Bool = false) {
        guard let id else {
            selectedAssetID = nil
            selectedAssetIDs = []
            return
        }
        if extend {
            if selectedAssetIDs.contains(id) {
                selectedAssetIDs.remove(id)
                selectedAssetID = selectedAssetIDs.first
            } else {
                selectedAssetIDs.insert(id)
                selectedAssetID = id
            }
        } else {
            selectedAssetID = id
            selectedAssetIDs = [id]
        }
    }

    func importFiles(_ urls: [URL], into timeline: TimelineModel) async {
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            let asset = await service.identifyAsset(url: url)

            if asset.fileType == .xmlTimeline {
                do {
                    let imported = try await service.importTimeline(url: url)
                    for a in imported.assets { add(a) }
                    timeline.addImported(imported.clips)
                    if imported.offlineCount > 0 {
                        alertMessage = "\(imported.offlineCount) file media tidak bisa dibuka (offline). Impor file media dengan nama yang sama untuk me-relink."
                    }
                } catch {
                    alertMessage = error.localizedDescription
                }
            } else {
                relinkOfflineAssets(matching: asset, in: timeline)
                add(asset)
                if autoProxy, asset.fileType == .video, asset.naturalSize.width >= 3840 {
                    Task { await generateProxy(for: asset, timeline: timeline) }
                }
            }
        }
    }

    private func add(_ asset: MediaAsset) {
        guard !assets.contains(where: { $0.url == asset.url }) else { return }
        assets.append(asset)
        if selectedAssetID == nil { selectAsset(asset.id) }
    }

    private func relinkOfflineAssets(matching new: MediaAsset, in timeline: TimelineModel) {
        guard new.isEditable else { return }
        func base(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }
        let stale = assets.filter { $0.isOffline && base($0.fileName) == base(new.fileName) }
        for old in stale {
            timeline.relink(old, to: new)
            assets.removeAll { $0.id == old.id }
        }
    }

    func remove(_ asset: MediaAsset, from timeline: TimelineModel) {
        timeline.removeClips(using: asset)
        assets.removeAll { $0.id == asset.id }
        selectedAssetIDs.remove(asset.id)
        if selectedAssetID == asset.id { selectedAssetID = selectedAssetIDs.first }
    }

    /// Membuat multicam clip dari media terpilih, disinkronkan lewat audio.
    func createMulticam(into timeline: TimelineModel) async {
        let picks = assets.filter { selectedAssetIDs.contains($0.id) && $0.isEditable }
        guard (MulticamBuilder.minAngles...MulticamBuilder.maxAngles).contains(picks.count) else {
            alertMessage = "Pilih \(MulticamBuilder.minAngles)–\(MulticamBuilder.maxAngles) klip di Browser (⌘-klik untuk memilih beberapa) lalu buat multicam."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let result = await MulticamBuilder.build(from: picks)
        timeline.appendMulticam(result.data, name: "Multicam (\(picks.count) angle)")
        if !result.unsynced.isEmpty {
            alertMessage = "Audio tidak bisa disinkronkan untuk: \(result.unsynced.joined(separator: ", ")). Angle itu ditempatkan di awal; geser manual bila perlu."
        }
    }

    func loadThumbnail(for asset: MediaAsset) async {
        guard thumbnails[asset.id] == nil else { return }
        switch asset.fileType {
        case .image:
            thumbnails[asset.id] = NSImage(contentsOf: asset.url)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            let time = CMTime(seconds: min(1, asset.duration / 2), preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                thumbnails[asset.id] = NSImage(cgImage: result.image, size: .zero)
            }
        default:
            break
        }
        guard asset.fileType == .video, filmstrips[asset.id] == nil,
              !loadingFilmstrips.contains(asset.id), asset.duration > 0 else { return }
        loadingFilmstrips.insert(asset.id)
        defer { loadingFilmstrips.remove(asset.id) }
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        let sampleCount = min(10, max(2, Int(asset.duration / 2)))
        let times = (0..<sampleCount).map {
            CMTime(seconds: asset.duration * Double($0) / Double(sampleCount - 1), preferredTimescale: 600)
        }
        let images = await Task.detached(priority: .utility) {
            times.compactMap { try? generator.copyCGImage(at: $0, actualTime: nil) }
        }.value
        filmstrips[asset.id] = images.map { NSImage(cgImage: $0, size: .zero) }
    }
}

// MARK: - Timeline

struct Snapshot: Identifiable, Codable {
    var id = UUID()
    var name: String
    var date = Date()
    var clips: [TimelineClip]
    var markIn: Double?
    var markOut: Double?
}

struct CompoundLevel {
    var parentClips: [TimelineClip]
    var compoundID: UUID
    var playhead: Double
    var name: String
}

@MainActor
@Observable
final class TimelineModel {
    private static let shuttleSteps: [Double] = [1, 2, 4, 8]

    var clips: [TimelineClip] = []
    var selectedClipID: UUID?
    var selectedClipIDs: Set<UUID> = []
    var playhead: Double = 0
    var isPlaying = false
    var isScrubbing = false
    var shuttleRate: Double = 0
    var zoom: Double = 40            // point per detik
    var tool: EditTool = .select
    var trimMode: TrimMode = .ripple
    var snapping = true
    var skimTime: Double?
    var markIn: Double?
    var markOut: Double?
    var isExporting = false
    var isExportSheetPresented = false
    var isTranscribing = false
    var roleMix: [AudioRole: RoleMix] = [:]
    var useProxies = false
    var colorManagement = ColorManagementMode.off
    var markers: [TimelineMarker] = []
    var detectedBPM: Double?
    var isAnalyzing = false
    var analysisStatus = ""
    var isTrackerPlacing = false
    var trackerPoint = CGPoint(x: 0.5, y: 0.5)   // dalam koordinat frame project (0...1 dari kiri-atas)
    var exportProgress = 0.0
    var exportStatus = ""
    var statusMessage: String?
    var renderSize = CGSize(width: 1920, height: 1080)
    private(set) var compoundStack: [CompoundLevel] = []
    private(set) var snapshots: [Snapshot] = []
    var isSnapshotsPresented = false

    private(set) var undoStack: [[TimelineClip]] = []
    private(set) var redoStack: [[TimelineClip]] = []
    private(set) var clipClipboard: [TimelineClip] = []

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var scopeOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var lastScopeBuffer: CVPixelBuffer?

    init() {
        player.actionAtItemEnd = .pause
        installTimeObserver()
    }

    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: CMTimeScale(projectFrameRate)), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    /// Frame rate project (24, 30, atau 60). Mengubah timecode, langkah frame, dan frame duration render/ekspor.
    private(set) var frameRate = projectFrameRate

    func setFrameRate(_ fps: Double) {
        guard supportedFrameRates.contains(fps), fps != projectFrameRate else { return }
        projectFrameRate = fps
        frameRate = fps
        installTimeObserver()
        playhead = (playhead * fps).rounded() / fps // tetap tepat di batas frame
        scheduleRebuild()
        statusMessage = "Frame rate project: \(Int(fps)) fps."
    }

    // MARK: Speed

    /// Kecepatan konstan (1 = normal). Durasi klip menyesuaikan sehingga potongan media yang dipakai tetap sama.
    func setSpeed(_ id: UUID, _ speed: Double) {
        setRetime(id, Retime(speed: Retime.clamp(speed)))
    }

    func setRetime(_ id: UUID, _ retime: Retime?) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].canRetime else {
            statusMessage = "Kecepatan hanya bisa diubah pada klip video atau audio biasa."
            return
        }
        checkpoint()
        clips[i].applyRetime(retime)
        avoidCollision(id)
        commit()
    }

    func applyRetimePreset(_ id: UUID, _ preset: Retime.Preset) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].canRetime else {
            statusMessage = "Kecepatan hanya bisa diubah pada klip video atau audio biasa."
            return
        }
        checkpoint()
        clips[i].applyPreset(preset)
        avoidCollision(id)
        commit()
    }

    /// Menambah titik kecepatan di playhead (atau di tengah klip bila playhead di luar klip).
    func addSpeedKey(_ id: UUID) {
        guard let c = clip(id), c.canRetime else { return }
        var r = c.retime ?? Retime()
        let local = (playhead > c.startTime + 0.05 && playhead < c.endTime - 0.05) ? playhead - c.startTime : c.duration / 2
        if r.keys.isEmpty { r.keys = [SpeedKey(time: 0, speed: r.speed), SpeedKey(time: c.duration, speed: r.speed)] }
        r.keys.append(SpeedKey(time: local, speed: r.speed(at: local)))
        r.keys.sort { $0.time < $1.time }
        setRetime(id, r)
    }

    func setSpeedKey(_ id: UUID, index: Int, speed: Double? = nil, time: Double? = nil) {
        guard var r = clip(id)?.retime, r.keys.indices.contains(index) else { return }
        if let speed { r.keys[index].speed = Retime.clamp(speed) }
        if let time { r.keys[index].time = max(0, time) }
        setRetime(id, r)
    }

    func removeSpeedKey(_ id: UUID, index: Int) {
        guard var r = clip(id)?.retime, r.keys.indices.contains(index) else { return }
        r.keys.remove(at: index)
        if r.keys.count == 1 { r = Retime(speed: r.keys[0].speed) }
        setRetime(id, r)
    }

    // MARK: Queries

    var totalDuration: Double { clips.map(\.endTime).max() ?? 0 }
    var selectedClip: TimelineClip? { clip(selectedClipID) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func clip(_ id: UUID?) -> TimelineClip? {
        guard let id else { return nil }
        return clips.first { $0.id == id }
    }

    // MARK: Selection

    func select(_ id: UUID?, extend: Bool = false) {
        guard let id else {
            selectedClipIDs = []
            selectedClipID = nil
            return
        }
        if extend {
            if selectedClipIDs.contains(id) {
                selectedClipIDs.remove(id)
                selectedClipID = selectedClipIDs.first
            } else {
                selectedClipIDs.insert(id)
                selectedClipID = id
            }
        } else {
            selectedClipIDs = [id]
            selectedClipID = id
        }
    }

    // MARK: Undo / mutation plumbing

    /// Simpan state sebelum perubahan. Dipanggil sekali per aksi (juga saat mulai menggeser slider).
    func checkpoint() {
        undoStack.append(clips)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(clips)
        clips = previous
        commit()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(clips)
        clips = next
        commit()
    }

    /// Hitung ulang posisi primary tanpa memicu rebuild (dipakai saat beberapa klip diubah berurutan).
    func reflowForBeats() { reflow() }

    func commit(sortKey: ((TimelineClip) -> Double)? = nil) {
        reflow(sortKey: sortKey)
        for i in clips.indices where clips[i].lane != 0 && clips[i].anchorID == nil {
            clips[i].anchorID = anchor(for: clips[i])
        }
        playhead = min(playhead, totalDuration)
        selectedClipIDs = selectedClipIDs.filter { id in clips.contains { $0.id == id } }
        if let s = selectedClipID, !selectedClipIDs.contains(s) { selectedClipID = selectedClipIDs.first }
        scheduleRebuild()
    }

    private func anchor(for c: TimelineClip) -> UUID? {
        clips.first { $0.lane == 0 && $0.startTime <= c.startTime + 0.0005 && c.startTime < $0.endTime - 0.0005 }?.id
    }

    /// Primary storyline bersifat magnetic: klip selalu rapat tanpa celah, urutan mengikuti sortKey.
    /// Klip connected ikut bergeser sebesar perpindahan klip primary tempat ia menempel.
    private func reflow(sortKey: ((TimelineClip) -> Double)? = nil) {
        let key = sortKey ?? { $0.startTime }
        var oldStarts: [UUID: Double] = [:]
        for c in clips where c.lane == 0 { oldStarts[c.id] = c.startTime }

        let order = clips.indices.filter { clips[$0].lane == 0 }
            .sorted { (key(clips[$0]), $0) < (key(clips[$1]), $1) }
        var t = 0.0
        var previous: Int?
        for i in clips.indices { clips[i].transitionOverlap = 0; clips[i].transitionOutOverlap = 0 }
        for i in order {
            var overlap = 0.0
            if let p = previous, let spec = clips[i].transition {
                // Transisi dibuat dengan menumpuk dua klip; maksimum separuh durasi klip terpendek.
                overlap = min(max(spec.duration, 0), min(clips[i].duration, clips[p].duration) * 0.5)
                clips[i].transitionOverlap = overlap
                clips[p].transitionOutOverlap = overlap
            }
            clips[i].startTime = t - overlap
            t = clips[i].startTime + clips[i].duration
            previous = i
        }

        for i in clips.indices where clips[i].lane != 0 {
            guard let a = clips[i].anchorID else { continue }
            if let old = oldStarts[a], let new = clips.first(where: { $0.id == a })?.startTime {
                clips[i].startTime = max(0, clips[i].startTime + new - old)
            } else if !clips.contains(where: { $0.id == a }) {
                clips[i].anchorID = nil
            }
        }
    }

    /// Collision avoidance: klip connected yang menabrak klip lain di lane-nya didorong ke lane berikutnya.
    func avoidCollision(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].lane != 0 else { return }
        let direction = clips[i].lane > 0 ? 1 : -1
        while clips.contains(where: {
            $0.id != id && $0.lane == clips[i].lane && $0.startTime < clips[i].endTime - 0.001 && clips[i].startTime < $0.endTime - 0.001
        }) {
            clips[i].lane += direction
        }
    }

    // MARK: Adding clips

    private func makeClip(_ asset: MediaAsset, range: ClosedRange<Double>? = nil) -> TimelineClip? {
        guard asset.isEditable else {
            statusMessage = "\(asset.fileName) tidak bisa ditambahkan ke timeline (video, gambar, atau audio)."
            return nil
        }
        var clip = TimelineClip(asset: asset, startTime: 0, duration: asset.duration > 0 ? asset.duration : 5, lane: 0)
        if let range {
            clip.offsetInAsset = range.lowerBound
            clip.duration = range.upperBound - range.lowerBound
        }
        return clip
    }

    private var primaryEnd: Double { clips.filter { $0.lane == 0 }.map(\.endTime).max() ?? 0 }

    /// Append (E): tambahkan di akhir primary storyline.
    func append(_ asset: MediaAsset, range: ClosedRange<Double>? = nil) {
        guard asset.fileType == .video || asset.fileType == .image else { connect(asset, range: range); return }
        guard var clip = makeClip(asset, range: range) else { return }
        checkpoint()
        clip.startTime = primaryEnd
        clips.append(clip)
        select(clip.id)
        commit()
    }

    /// Insert (W): sisipkan di playhead pada primary storyline, klip di bawahnya dibelah.
    func insert(_ asset: MediaAsset, at time: Double? = nil, range: ClosedRange<Double>? = nil) {
        guard asset.fileType == .video || asset.fileType == .image else { connect(asset, at: time, range: range); return }
        guard var clip = makeClip(asset, range: range) else { return }
        let t = min(time ?? playhead, primaryEnd)
        checkpoint()
        if let i = clips.firstIndex(where: { $0.lane == 0 && $0.startTime + 0.03 < t && t < $0.endTime - 0.03 }) {
            split(index: i, at: t)
        }
        clip.startTime = t
        clips.append(clip)
        select(clip.id)
        let newID = clip.id
        commit { $0.id == newID ? t - 0.0005 : $0.startTime }
    }

    /// Connect (Q): tempel di atas (video) atau di bawah (audio) storyline pada posisi playhead.
    func connect(_ asset: MediaAsset, at time: Double? = nil, lane preferred: Int? = nil, range: ClosedRange<Double>? = nil) {
        guard var clip = makeClip(asset, range: range) else { return }
        clip.startTime = time ?? playhead
        if asset.fileType == .audio { clip.role = AudioRole.guess(for: asset) }
        clip.lane = preferred ?? (asset.fileType == .audio ? clip.role.lane : 1)
        checkpoint()
        clips.append(clip)
        avoidCollision(clip.id)
        select(clip.id)
        commit()
    }

    func addImported(_ imported: [TimelineClip]) {
        guard !imported.isEmpty else { return }
        checkpoint()
        clips.append(contentsOf: imported)
        imported.forEach { avoidCollision($0.id) }
        commit()
    }

    func appendMulticam(_ data: MulticamData, name: String) {
        var clip = TimelineClip(asset: .container(name: name, type: .multicam, duration: data.contentDuration),
                                startTime: primaryEnd, duration: data.contentDuration, lane: 0)
        clip.multicam = data
        checkpoint()
        clips.append(clip)
        select(clip.id)
        commit()
    }

    // MARK: Editing

    func updateClip(_ id: UUID, _ change: (inout TimelineClip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[i])
        scheduleRebuild()
    }

    private func split(index i: Int, at t: Double) {
        let d = t - clips[i].startTime
        let leftID = clips[i].id
        var right = clips[i].splitOff(at: d)
        right.id = UUID()
        right.startTime = t
        clips.append(right)
        if clips[i].lane == 0 {
            // Klip connected yang berada di sisi kanan potongan pindah menempel ke potongan kanan.
            for j in clips.indices where clips[j].anchorID == leftID && clips[j].startTime >= t - 0.0005 {
                clips[j].anchorID = right.id
            }
        }
    }

    func split(_ id: UUID, at t: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              clips[i].startTime + 0.03 < t, t < clips[i].endTime - 0.03 else { return }
        checkpoint()
        split(index: i, at: t)
        commit()
    }

    /// Cmd+B: belah klip terpilih di playhead, atau semua klip di bawah playhead bila tidak ada yang terpilih.
    func splitAtPlayhead() {
        let t = playhead
        let hit = clips.indices.filter { clips[$0].startTime + 0.03 < t && t < clips[$0].endTime - 0.03 }
        let targets = hit.filter { selectedClipIDs.contains(clips[$0].id) }
        let chosen = targets.isEmpty ? hit : targets
        guard !chosen.isEmpty else { return }
        checkpoint()
        chosen.forEach { split(index: $0, at: t) }
        commit()
    }

    func deleteSelected() {
        guard !selectedClipIDs.isEmpty else { return }
        checkpoint()
        clips.removeAll { selectedClipIDs.contains($0.id) }
        select(nil)
        commit()
    }

    func copySelected() {
        let selected = clips.filter { selectedClipIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        clipClipboard = selected
    }

    func pasteClips() {
        guard !clipClipboard.isEmpty else {
            statusMessage = "Salin klip terlebih dulu."
            return
        }
        let sourceStart = clipClipboard.map(\.startTime).min() ?? 0
        checkpoint()
        let copies = clipClipboard.map { source -> TimelineClip in
            var copy = source
            copy.id = UUID()
            copy.startTime = max(0, playhead + source.startTime - sourceStart)
            copy.anchorID = nil
            return copy
        }
        clips.append(contentsOf: copies)
        copies.filter { $0.lane != 0 }.forEach { avoidCollision($0.id) }
        select(copies.first?.id)
        commit()
    }

    /// Menggeser klip. Klip primary tertukar urutannya saat melewati titik tengah tetangga;
    /// klip connected bisa berpindah lane (laneShift) dan tidak pernah bertumpuk.
    func moveClip(_ id: UUID, toStart newStart: Double, laneShift: Int = 0) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        if clips[i].lane == 0 {
            commit { $0.id == id ? newStart + $0.duration / 2 - 0.001 : $0.startTime + $0.duration / 2 }
        } else {
            clips[i].startTime = max(0, newStart)
            let shifted = clips[i].lane + laneShift
            clips[i].lane = clips[i].asset.fileType == .audio ? min(-1, shifted) : max(1, shifted)
            clips[i].anchorID = nil
            avoidCollision(id)
            commit()
        }
    }

    // MARK: Trim (ripple, roll, slip, slide)

    /// Batas delta trim (detik) supaya klip tidak melewati ujung media sumbernya.
    func clampedTrim(_ clip: TimelineClip, edge: ClipEdge, delta: Double) -> Double {
        switch edge {
        case .head:
            return min(max(delta, clip.headRoom), clip.duration - 0.1)
        case .tail:
            return min(max(delta, -(clip.duration - 0.1)), max(0, clip.tailRoom))
        }
    }

    /// Sisa media sumber (detik media) setelah ujung klip.
    private func sourceTailRoom(_ clip: TimelineClip) -> Double {
        clip.asset.duration > 0 ? clip.asset.duration - clip.offsetInAsset - clip.sourceSpan : .infinity
    }

    /// Ripple.
    func trim(_ id: UUID, edge: ClipEdge, delta rawDelta: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let delta = clampedTrim(clips[i], edge: edge, delta: rawDelta)
        guard abs(delta) > 0.001 else { return }
        checkpoint()
        switch edge {
        case .head:
            clips[i].trimHead(by: delta)
            if clips[i].lane != 0 { clips[i].startTime += delta } // primary mengikuti reflow
            clips[i].duration -= delta
        case .tail:
            clips[i].duration += delta
        }
        avoidCollision(id)
        commit()
    }

    /// Klip bersebelahan persis (tanpa celah) di lane yang sama.
    func neighbor(of clip: TimelineClip, after: Bool) -> TimelineClip? {
        clips.first {
            $0.id != clip.id && $0.lane == clip.lane
                && abs(after ? $0.startTime - clip.endTime : $0.endTime - clip.startTime) < 0.002
        }
    }

    func rollRange(left: TimelineClip, right: TimelineClip) -> ClosedRange<Double> {
        let lo = max(-(left.duration - 0.1), right.headRoom)
        let hi = min(right.duration - 0.1, max(0, left.tailRoom))
        return min(lo, 0)...max(hi, 0)
    }

    /// Roll: titik potong antara dua klip bergeser, durasi total tetap.
    func roll(left: UUID, right: UUID, delta rawDelta: Double) {
        guard let l = clips.firstIndex(where: { $0.id == left }), let r = clips.firstIndex(where: { $0.id == right }) else { return }
        let range = rollRange(left: clips[l], right: clips[r])
        let delta = min(max(rawDelta, range.lowerBound), range.upperBound)
        guard abs(delta) > 0.001 else { return }
        checkpoint()
        clips[l].duration += delta
        clips[r].trimHead(by: delta)
        clips[r].startTime += delta
        clips[r].duration -= delta
        commit()
    }

    func slipRange(_ clip: TimelineClip) -> ClosedRange<Double> {
        -clip.offsetInAsset...max(0, min(sourceTailRoom(clip), 100_000))
    }

    /// Slip: isi klip bergeser, posisi dan durasi tetap.
    func slip(_ id: UUID, delta rawDelta: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let range = slipRange(clips[i])
        let delta = min(max(rawDelta, range.lowerBound), range.upperBound)
        guard abs(delta) > 0.001 else { return }
        checkpoint()
        clips[i].offsetInAsset += delta
        commit()
    }

    func slideRange(_ clip: TimelineClip) -> ClosedRange<Double>? {
        guard let l = neighbor(of: clip, after: false), let r = neighbor(of: clip, after: true) else { return nil }
        let lo = max(-(l.duration - 0.1), r.headRoom)
        let hi = min(r.duration - 0.1, max(0, l.tailRoom))
        return min(lo, 0)...max(hi, 0)
    }

    /// Slide: klip bergeser, klip di kiri memanjang/memendek dan klip di kanan menyesuaikan kepalanya.
    func slide(_ id: UUID, delta rawDelta: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              let range = slideRange(clips[i]),
              let l = clips.firstIndex(where: { $0.id == neighbor(of: clips[i], after: false)?.id }),
              let r = clips.firstIndex(where: { $0.id == neighbor(of: clips[i], after: true)?.id }) else {
            statusMessage = "Slide membutuhkan klip di kiri dan kanan yang bersebelahan."
            return
        }
        let delta = min(max(rawDelta, range.lowerBound), range.upperBound)
        guard abs(delta) > 0.001 else { return }
        checkpoint()
        clips[l].duration += delta
        clips[i].startTime += delta
        clips[r].trimHead(by: delta)
        clips[r].startTime += delta
        clips[r].duration -= delta
        commit()
    }

    /// Snap tepi klip (awal atau akhir) ke playhead, awal timeline, dan tepi klip lain.
    func snappedStart(_ start: Double, duration: Double, excluding id: UUID) -> Double {
        guard snapping else { return start }
        let threshold = 8 / zoom
        var points = [0, playhead] + markers.map(\.time)
        for c in clips where c.id != id { points += [c.startTime, c.endTime] }
        var best: Double?
        for p in points {
            for edge in [start, start + duration] {
                let d = p - edge
                if abs(d) < threshold, abs(d) < abs(best ?? .infinity) { best = d }
            }
        }
        return start + (best ?? 0)
    }

    func relink(_ old: MediaAsset, to new: MediaAsset) {
        for i in clips.indices {
            if clips[i].asset.id == old.id { clips[i].asset = new }
            for t in clips[i].takes.indices where clips[i].takes[t].asset.id == old.id { clips[i].takes[t].asset = new }
        }
        scheduleRebuild()
    }

    func removeClips(using asset: MediaAsset) {
        guard clips.contains(where: { $0.asset.id == asset.id }) else { return }
        checkpoint()
        clips.removeAll { $0.asset.id == asset.id }
        commit()
    }

    // MARK: Compound clips

    func makeCompound() {
        let selected = clips.filter { selectedClipIDs.contains($0.id) }
        guard !selected.isEmpty else {
            statusMessage = "Pilih satu atau lebih klip untuk dijadikan compound clip."
            return
        }
        let origin = selected.map(\.startTime).min()!
        let end = selected.map(\.endTime).max()!
        let primaryInside = clips.contains { c in
            c.lane == 0 && !selectedClipIDs.contains(c.id) && c.startTime < end - 0.001 && c.endTime > origin + 0.001
        }
        guard !primaryInside else {
            statusMessage = "Klip primary yang dipilih harus berdekatan (tidak ada klip lain di antaranya)."
            return
        }

        let lanes = Set(selected.map(\.lane))
        let compoundLane = lanes.count == 1 ? lanes.first! : 0
        let children = selected.map { c -> TimelineClip in
            var x = c
            x.startTime -= origin
            if lanes.count == 1 { x.lane = 0 }
            x.anchorID = nil
            return x
        }
        var compound = TimelineClip(
            asset: .container(name: "Compound Clip", type: .compound, duration: end - origin),
            startTime: origin, duration: end - origin, lane: compoundLane)
        compound.children = children

        checkpoint()
        clips.removeAll { selectedClipIDs.contains($0.id) }
        clips.append(compound)
        select(compound.id)
        commit()
    }

    func breakApartSelected() {
        guard let id = selectedClipID, let i = clips.firstIndex(where: { $0.id == id }), clips[i].isCompound else {
            statusMessage = "Pilih compound clip untuk dipecah."
            return
        }
        var kids = clips[i].windowedChildren()
        if clips[i].lane != 0 { for k in kids.indices { kids[k].lane += clips[i].lane } }
        checkpoint()
        clips.remove(at: i)
        clips.append(contentsOf: kids)
        select(nil)
        kids.forEach { select($0.id, extend: true) }
        commit()
    }

    /// Buka compound clip untuk diedit sebagai timeline sendiri.
    func openCompound() {
        guard let id = selectedClipID, let c = clip(id), c.isCompound else {
            statusMessage = "Pilih compound clip untuk dibuka."
            return
        }
        pause()
        compoundStack.append(CompoundLevel(parentClips: clips, compoundID: id, playhead: playhead, name: c.asset.fileName))
        clips = c.children
        undoStack = []
        redoStack = []
        select(nil)
        playhead = 0
        commit()
    }

    func closeCompound() {
        guard let level = compoundStack.popLast() else { return }
        pause()
        var parent = level.parentClips
        if let i = parent.firstIndex(where: { $0.id == level.compoundID }) {
            let content = totalDuration
            parent[i].children = clips
            parent[i].asset.duration = content
            if parent[i].offsetInAsset + parent[i].duration > content {
                parent[i].duration = max(0.1, content - parent[i].offsetInAsset)
            }
        }
        clips = parent
        undoStack = []
        redoStack = []
        select(level.compoundID)
        playhead = level.playhead
        commit()
    }

    // MARK: Audition

    func addTake(to id: UUID, asset: MediaAsset) {
        guard let i = clips.firstIndex(where: { $0.id == id }), !clips[i].isContainer else {
            statusMessage = "Pilih klip biasa di timeline untuk dijadikan audition."
            return
        }
        guard asset.isEditable, asset.fileType == clips[i].asset.fileType else {
            statusMessage = "Take harus berjenis sama dengan klip (video atau audio)."
            return
        }
        checkpoint()
        if clips[i].takes.isEmpty { clips[i].takes = [Take(asset: clips[i].asset, offsetInAsset: clips[i].offsetInAsset)] }
        clips[i].takes[clips[i].activeTake].offsetInAsset = clips[i].offsetInAsset
        clips[i].takes.append(Take(asset: asset, offsetInAsset: 0))
        clips[i].activeTake = clips[i].takes.count - 1
        applyTake(i)
        commit()
    }

    func cycleTake(_ id: UUID, by step: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].isAudition else { return }
        checkpoint()
        let count = clips[i].takes.count
        clips[i].takes[clips[i].activeTake].offsetInAsset = clips[i].offsetInAsset
        clips[i].activeTake = ((clips[i].activeTake + step) % count + count) % count
        applyTake(i)
        commit()
    }

    private func applyTake(_ i: Int) {
        let take = clips[i].takes[clips[i].activeTake]
        clips[i].asset = take.asset
        clips[i].offsetInAsset = take.offsetInAsset
        if take.asset.duration > 0 {
            clips[i].duration = min(clips[i].duration, max(0.1, take.asset.duration - take.offsetInAsset))
        }
    }

    /// Selesaikan audition: hanya take aktif yang dipertahankan.
    func finalizeAudition(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].isAudition else { return }
        checkpoint()
        clips[i].takes = []
        clips[i].activeTake = 0
        commit()
    }

    // MARK: Multicam

    /// Ganti angle di posisi playhead. Saat playhead berada di tengah klip, klip dibelah (seperti FCP)
    /// sehingga pergantian angle tercatat sebagai potongan baru.
    func switchAngle(_ index: Int, video: Bool = true, audio: Bool = true) {
        let t = playhead
        func contains(_ c: TimelineClip) -> Bool { c.multicam != nil && c.startTime - 0.001 <= t && t < c.endTime }
        let target = clips.first { selectedClipIDs.contains($0.id) && contains($0) }
            ?? clips.filter(contains).min { $0.lane < $1.lane }
        guard let id = target?.id, var i = clips.firstIndex(where: { $0.id == id }),
              let mc = clips[i].multicam, mc.angles.indices.contains(index) else { return }

        checkpoint()
        if t > clips[i].startTime + 0.03, t < clips[i].endTime - 0.03 {
            split(index: i, at: t)
            i = clips.count - 1
        }
        if video { clips[i].multicam?.activeVideo = index }
        if audio { clips[i].multicam?.activeAudio = index }
        select(clips[i].id)
        commit()
    }

    // MARK: Keyframes

    /// Waktu media di playhead untuk klip ini, atau nil bila playhead di luar klip.
    func keyframeTime(for clip: TimelineClip) -> Double? {
        guard playhead >= clip.startTime - 0.001, playhead <= clip.endTime + 0.001 else { return nil }
        return clip.mediaTime(at: playhead)
    }

    /// Nilai properti pada playhead (memperhitungkan keyframe).
    func currentValue(_ id: UUID, _ p: AnimProperty) -> Double {
        guard let c = clip(id) else { return p.defaultValue }
        return c.value(p, atMedia: c.mediaTime(at: min(max(playhead, c.startTime), c.endTime)))
    }

    /// Mengubah nilai. Bila properti sudah dianimasikan, nilai disimpan sebagai keyframe di playhead.
    func setValue(_ id: UUID, _ p: AnimProperty, _ value: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let v = min(max(value, p.range.lowerBound), p.range.upperBound)
        if clips[i].isAnimated(p), let t = keyframeTime(for: clips[i]) {
            clips[i].tracks[p]?.set(time: t, value: v)
        } else {
            clips[i].setStaticValue(p, v)
        }
        scheduleRebuild()
    }

    func hasKeyframe(_ id: UUID, _ p: AnimProperty) -> Bool {
        guard let c = clip(id), let t = keyframeTime(for: c) else { return false }
        return c.tracks[p]?.index(near: t) != nil
    }

    /// Tambah atau hapus keyframe di playhead.
    func toggleKeyframe(_ id: UUID, _ p: AnimProperty) {
        guard let i = clips.firstIndex(where: { $0.id == id }), let t = keyframeTime(for: clips[i]) else {
            statusMessage = "Geser playhead ke dalam klip untuk membuat keyframe."
            return
        }
        checkpoint()
        let current = clips[i].value(p, atMedia: t)
        var track = clips[i].tracks[p] ?? KeyframeTrack()
        if track.index(near: t) != nil {
            track.remove(near: t)
            if track.isEmpty { clips[i].setStaticValue(p, current) } // animasi dimatikan, nilai terakhir dipertahankan
        } else {
            track.set(time: t, value: current)
        }
        clips[i].tracks[p] = track.isEmpty ? nil : track
        scheduleRebuild()
    }

    /// Kembalikan properti ke nilai bawaan dan hapus keyframe-nya.
    func resetProperties(_ id: UUID, _ properties: [AnimProperty]) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        for p in properties {
            clips[i].tracks[p] = nil
            clips[i].setStaticValue(p, p.defaultValue)
        }
        scheduleRebuild()
    }

    func clearKeyframes(_ id: UUID, _ p: AnimProperty) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].isAnimated(p) else { return }
        checkpoint()
        clips[i].setStaticValue(p, currentValue(id, p))
        clips[i].tracks[p] = nil
        scheduleRebuild()
    }

    /// Kurva segmen keyframe yang sedang berada di bawah playhead.
    func easing(_ id: UUID, _ p: AnimProperty) -> Easing? {
        guard let c = clip(id), let t = keyframeTime(for: c), let track = c.tracks[p],
              let k = track.keys.lastIndex(where: { $0.time <= t + KeyframeTrack.tolerance }) else { return nil }
        return track.keys[k].easing
    }

    func setEasing(_ id: UUID, _ p: AnimProperty, _ easing: Easing) {
        guard let i = clips.firstIndex(where: { $0.id == id }), let t = keyframeTime(for: clips[i]),
              let k = clips[i].tracks[p]?.keys.lastIndex(where: { $0.time <= t + KeyframeTrack.tolerance }) else { return }
        clips[i].tracks[p]?.keys[k].easing = easing
        scheduleRebuild()
    }

    func jumpToKeyframe(forward: Bool) {
        guard let c = selectedClip else { return }
        let times = c.tracks.values.flatMap { $0.keys.map { c.startTime + ($0.time - c.offsetInAsset) } }.sorted()
        let target = forward ? times.first { $0 > playhead + 0.02 } : times.last { $0 < playhead - 0.02 }
        if let target { seek(to: target) }
    }

    // MARK: Versions (snapshot)

    func replaceAssetInCompoundStack(_ new: MediaAsset) {
        for l in compoundStack.indices { for i in compoundStack[l].parentClips.indices { compoundStack[l].parentClips[i].replaceAsset(new) } }
    }

    /// Klip tingkat atas, walau saat ini ada compound yang sedang dibuka.
    var rootClips: [TimelineClip] { compoundStack.first?.parentClips ?? clips }

    @discardableResult
    func takeSnapshot(named name: String) -> Snapshot {
        let snapshot = Snapshot(name: name.isEmpty ? "Version \(snapshots.count + 1)" : name, clips: rootClips, markIn: markIn, markOut: markOut)
        snapshots.insert(snapshot, at: 0)
        return snapshot
    }

    /// Kembali ke versi lama. Keadaan sekarang disimpan otomatis dulu supaya rollback sendiri bisa dibatalkan.
    func restoreSnapshot(_ id: UUID) {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        takeSnapshot(named: "Auto — sebelum kembali ke “\(snapshot.name)”")
        compoundStack = []
        checkpoint()
        clips = snapshot.clips
        markIn = snapshot.markIn
        markOut = snapshot.markOut
        select(nil)
        commit()
    }

    func deleteSnapshot(_ id: UUID) { snapshots.removeAll { $0.id == id } }

    func renameSnapshot(_ id: UUID, to name: String) {
        guard let i = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[i].name = name
    }

    /// Mengganti seluruh isi project (dipakai saat membuka file).
    func replaceProject(clips newClips: [TimelineClip], snapshots newSnapshots: [Snapshot], markIn: Double?, markOut: Double?) {
        pause()
        compoundStack = []
        undoStack = []
        redoStack = []
        clips = newClips
        snapshots = newSnapshots
        self.markIn = markIn
        self.markOut = markOut
        playhead = 0
        select(nil)
        commit()
    }

    // MARK: Stabilizer & tracker

    /// Sign koreksi Vision → posisi Core Image/compositor (ditentukan lewat uji terhadap video dengan getaran yang diketahui).
    static let stabilizeSignX = -1.0
    static let stabilizeSignY = -1.0

    private func displayedSize(of clip: TimelineClip) -> CGSize {
        let nat = clip.asset.naturalSize
        guard nat.width > 0, nat.height > 0 else { return renderSize }
        let fit = min(renderSize.width / nat.width, renderSize.height / nat.height)
        return CGSize(width: nat.width * fit, height: nat.height * fit)
    }

    /// Stabilisasi klip: menganalisis getaran kamera lalu membuat keyframe posisi dan zoom pengisi tepi.
    func stabilize(_ id: UUID, smoothing: Double = 1.0) async {
        guard let clip = clip(id), clip.asset.fileType == .video, !clip.isContainer else {
            statusMessage = "Pilih klip video biasa untuk distabilkan."
            return
        }
        guard !clip.isRetimed else {
            statusMessage = "Kembalikan kecepatan klip ke 1× dulu, baru stabilkan."
            return
        }
        isAnalyzing = true
        analysisStatus = "Menganalisis gerak kamera…"
        defer { isAnalyzing = false; analysisStatus = "" }
        guard let result = await Stabilizer.analyze(url: clip.asset.url, start: clip.offsetInAsset,
                                                    duration: clip.duration, smoothing: smoothing) else {
            statusMessage = "Stabilisasi gagal: video terlalu pendek atau tidak bisa dibaca."
            return
        }
        let size = displayedSize(of: clip)
        let keys: (x: [Keyframe], y: [Keyframe]) = (
            zip(result.times, result.dx).map { Keyframe(time: $0, value: $1 * Self.stabilizeSignX * size.width, easing: .linear) },
            zip(result.times, result.dy).map { Keyframe(time: $0, value: $1 * Self.stabilizeSignY * size.height, easing: .linear) })
        let maxX = result.dx.map { abs($0) }.max() ?? 0, maxY = result.dy.map { abs($0) }.max() ?? 0
        let zoom = 1 + 2 * max(maxX, maxY) + 0.01 // pembesaran untuk menutup tepi yang terbuka akibat koreksi

        checkpoint()
        updateClip(id) {
            $0.tracks[.positionX] = KeyframeTrack(keys: keys.x)
            $0.tracks[.positionY] = KeyframeTrack(keys: keys.y)
            if !$0.isAnimated(.scale) { $0.scale = max($0.scale, zoom) }
        }
    }

    /// Titik pelacakan dalam koordinat frame sumber (0...1), dari titik di frame project.
    private func trackerPointInSource(_ source: TimelineClip) -> CGPoint {
        let size = displayedSize(of: source)
        let x = (trackerPoint.x * renderSize.width - (renderSize.width - size.width) / 2) / size.width
        let y = (trackerPoint.y * renderSize.height - (renderSize.height - size.height) / 2) / size.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Klip target (judul / klip connected) mengikuti objek yang ditandai di video primary di bawah playhead.
    func trackPoint(for targetID: UUID) async {
        guard let target = clip(targetID), target.lane != 0 else {
            statusMessage = "Pilih judul atau klip connected yang akan mengikuti objek."
            return
        }
        guard let source = clips.first(where: {
            $0.lane == 0 && $0.asset.fileType == .video && !$0.isContainer
                && $0.startTime <= playhead + 0.001 && playhead < $0.endTime
        }) else {
            statusMessage = "Tidak ada klip video di primary storyline pada posisi playhead."
            return
        }
        guard !source.isRetimed else {
            statusMessage = "Klip sumber memakai speed ramp; kembalikan ke 1× dulu agar pelacakan akurat."
            return
        }
        let start = source.mediaTime(at: playhead)
        let duration = min(source.endTime, target.endTime) - playhead
        guard duration > 0.2 else { statusMessage = "Rentang pelacakan terlalu pendek."; return }

        isAnalyzing = true
        analysisStatus = "Melacak objek…"
        defer { isAnalyzing = false; analysisStatus = "" }
        let origin = trackerPointInSource(source)
        let points = await PointTracker.track(url: source.asset.url, start: start, duration: duration, from: origin)
        guard points.count > 2 else { statusMessage = "Objek tidak bisa dilacak. Pilih titik dengan tekstur yang jelas."; return }

        let size = displayedSize(of: source)
        var xs: [Keyframe] = [], ys: [Keyframe] = []
        for p in points {
            let timelineTime = source.startTime + (p.time - source.offsetInAsset)
            let t = target.mediaTime(at: timelineTime)
            xs.append(Keyframe(time: t, value: (p.x - origin.x) * size.width, easing: .linear))
            ys.append(Keyframe(time: t, value: -(p.y - origin.y) * size.height, easing: .linear))
        }
        checkpoint()
        updateClip(targetID) {
            $0.tracks[.positionX] = KeyframeTrack(keys: xs)
            $0.tracks[.positionY] = KeyframeTrack(keys: ys)
        }
        statusMessage = points.last!.time < start + duration - 0.5
            ? "Pelacakan berhenti di \(timecodeString(source.startTime + points.last!.time - source.offsetInAsset)) karena objek hilang."
            : nil
    }

    // MARK: Nodes & grade clipboard

    var gradeClipboard: [ColorNode]?

    func addNode(to id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        let position = min(clips[i].activeNode + 1, clips[i].nodes.count)
        clips[i].nodes.insert(ColorNode(name: "Node \(clips[i].nodes.count + 1)"), at: position)
        clips[i].activeNode = position
        scheduleRebuild()
    }

    func selectNode(_ index: Int, in id: UUID) {
        updateClip(id) { $0.activeNode = min(max(index, 0), $0.nodes.count - 1) }
    }

    func deleteActiveNode(in id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].nodes.count > 1 else { return }
        checkpoint()
        clips[i].nodes.remove(at: clips[i].activeNode)
        clips[i].activeNode = min(clips[i].activeNode, clips[i].nodes.count - 1)
        scheduleRebuild()
    }

    func toggleNode(_ index: Int, in id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].nodes.indices.contains(index) else { return }
        checkpoint()
        clips[i].nodes[index].enabled.toggle()
        scheduleRebuild()
    }

    func moveActiveNode(in id: UUID, by step: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let from = clips[i].activeNode, to = from + step
        guard clips[i].nodes.indices.contains(from), clips[i].nodes.indices.contains(to) else { return }
        checkpoint()
        clips[i].nodes.swapAt(from, to)
        clips[i].activeNode = to
        scheduleRebuild()
    }

    func renameActiveNode(in id: UUID, to name: String) {
        updateClip(id) { $0.nodes[min(max($0.activeNode, 0), $0.nodes.count - 1)].name = name }
    }

    func copyGrade(from id: UUID) {
        guard let c = clip(id), c.asset.fileType == .video || c.isAdjustmentLayer else { return }
        gradeClipboard = c.nodes
    }

    /// Tempel grade ke semua klip video terpilih (id node dibuat baru).
    func pasteGrade() {
        guard let source = gradeClipboard else {
            statusMessage = "Salin grade dari sebuah klip terlebih dulu."
            return
        }
        let targets = clips.filter {
            selectedClipIDs.contains($0.id) && ($0.asset.fileType == .video || $0.isAdjustmentLayer)
        }
        guard !targets.isEmpty else { statusMessage = "Pilih klip video atau adjustment layer tujuan."; return }
        checkpoint()
        for t in targets {
            updateClip(t.id) {
                $0.nodes = source.map { var n = $0; n.id = UUID(); return n }
                $0.activeNode = min($0.activeNode, $0.nodes.count - 1)
            }
        }
    }

    // MARK: Titles, transitions, looks

    /// Tambah judul di posisi playhead sebagai klip connected.
    func addTitle(_ preset: TitlePreset, text: String? = nil, duration: Double = 4) {
        let spec = TitleSpec.make(preset, text: text)
        var clip = TimelineClip(asset: .container(name: spec.text, type: .title, duration: 0),
                                startTime: playhead, duration: duration, lane: 1)
        clip.title = spec
        switch preset {
        case .socialHook, .subtitlePop:
            clip.tracks[.opacity] = KeyframeTrack(keys: [
                Keyframe(time: 0, value: 0, easing: .easeOut),
                Keyframe(time: 0.12, value: 1)
            ])
            clip.tracks[.scale] = KeyframeTrack(keys: [
                Keyframe(time: 0, value: 0.78, easing: .easeOut),
                Keyframe(time: 0.22, value: 1.06, easing: .easeInOut),
                Keyframe(time: 0.38, value: 1)
            ])
            clip.fadeOut = min(0.18, duration / 3)
        case .newsBanner:
            clip.tracks[.opacity] = KeyframeTrack(keys: [
                Keyframe(time: 0, value: 0, easing: .easeOut),
                Keyframe(time: 0.22, value: 1)
            ])
            clip.tracks[.positionX] = KeyframeTrack(keys: [
                Keyframe(time: 0, value: -420, easing: .easeOut),
                Keyframe(time: 0.32, value: 0)
            ])
        case .cinematic, .endCard:
            clip.tracks[.opacity] = KeyframeTrack(keys: [
                Keyframe(time: 0, value: 0, easing: .easeInOut),
                Keyframe(time: 0.65, value: 1)
            ])
            clip.fadeOut = min(0.65, duration / 3)
        default:
            break
        }
        checkpoint()
        clips.append(clip)
        avoidCollision(clip.id)
        select(clip.id)
        commit()
    }

    func updateTitle(_ id: UUID, _ change: (inout TitleSpec) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }), var spec = clips[i].title else { return }
        change(&spec)
        clips[i].title = spec
        clips[i].asset.fileName = spec.text.split(separator: "\n").first.map(String.init) ?? "Judul"
        scheduleRebuild()
    }

    func setTransition(_ id: UUID, _ spec: TransitionSpec?) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        guard clips[i].lane == 0, !clips[i].isTitle else {
            statusMessage = "Transisi hanya bisa dipasang pada klip di primary storyline."
            return
        }
        guard clips.filter({ $0.lane == 0 && $0.startTime < clips[i].startTime - 0.001 }).isEmpty == false else {
            statusMessage = "Transisi dipasang di awal klip yang punya klip sebelumnya."
            return
        }
        checkpoint()
        clips[i].transition = spec
        commit()
    }

    /// Terapkan transisi pada awal semua klip primary terpilih (atau klip terpilih saja).
    func applyTransition(_ kind: TransitionKind, duration: Double = 1) {
        let targets = clips.filter { selectedClipIDs.contains($0.id) && $0.lane == 0 }
        guard !targets.isEmpty else {
            statusMessage = "Pilih klip di primary storyline untuk dipasangi transisi."
            return
        }
        targets.forEach { setTransition($0.id, TransitionSpec(kind: kind, duration: duration)) }
    }

    func applyLook(_ look: LookPreset) {
        let targets = clips.filter {
            selectedClipIDs.contains($0.id) && ($0.asset.fileType == .video || $0.isAdjustmentLayer)
        }
        guard !targets.isEmpty else {
            statusMessage = "Pilih klip video atau adjustment layer untuk diberi look."
            return
        }
        checkpoint()
        for t in targets { updateClip(t.id) { look.apply(to: &$0.grade) } }
    }

    func applyKenBurns(to id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              clips[i].asset.fileType == .image || clips[i].asset.fileType == .video else {
            statusMessage = "Ken Burns hanya bisa dipasang pada klip gambar atau video."
            return
        }
        let start = clips[i].offsetInAsset
        let end = start + clips[i].duration
        checkpoint()
        clips[i].tracks[.scale] = KeyframeTrack(keys: [
            Keyframe(time: start, value: 1, easing: .easeInOut),
            Keyframe(time: end, value: 1.15, easing: .easeInOut)
        ])
        clips[i].tracks[.positionX] = KeyframeTrack(keys: [
            Keyframe(time: start, value: -28, easing: .easeInOut),
            Keyframe(time: end, value: 28, easing: .easeInOut)
        ])
        clips[i].tracks[.positionY] = KeyframeTrack(keys: [
            Keyframe(time: start, value: 18, easing: .easeInOut),
            Keyframe(time: end, value: -18, easing: .easeInOut)
        ])
        commit()
    }

    /// Buat layer grading transparan di atas rentang pilihan, atau mulai dari playhead selama lima detik.
    func addAdjustmentLayer() {
        let selected = clips.filter { selectedClipIDs.contains($0.id) && $0.lane >= 0 && !$0.isTitle && !$0.isAdjustmentLayer }
        let start = selected.map(\.startTime).min() ?? playhead
        let end = selected.map(\.endTime).max() ?? (playhead + 5)
        let duration = max(0.1, end - start)
        let lane = max(1, (clips.map(\.lane).max() ?? 0) + 1)
        let asset = MediaAsset.container(name: "Adjustment Layer", type: .adjustment, duration: duration)
        let clip = TimelineClip(asset: asset, startTime: start, duration: duration, lane: lane)
        checkpoint()
        clips.append(clip)
        select(clip.id)
        commit()
    }

    // MARK: Captions

    /// Tambah cue sebagai klip judul di lane caption khusus (waktu absolut di timeline).
    func addCaptions(_ cues: [CaptionCue], timeOffset: Double = 0) {
        guard !cues.isEmpty else { return }
        checkpoint()
        var firstID: UUID?
        for cue in cues {
            var clip = TimelineClip(asset: .container(name: cue.text, type: .title, duration: 0),
                                    startTime: max(0, cue.start + timeOffset), duration: max(0.2, cue.end - cue.start), lane: 2)
            clip.title = TitleSpec.make(.subtitle, text: cue.text)
            clip.fadeIn = min(0.12, clip.duration / 3)
            clip.fadeOut = min(0.12, clip.duration / 3)
            if firstID == nil { firstID = clip.id }
            clips.append(clip)
            avoidCollision(clip.id)
        }
        if let firstID { select(firstID) }
        commit()
    }

    func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.message = "Pilih file subtitle (.srt)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            let cues = SRT.parse(text)
            guard !cues.isEmpty else { statusMessage = "Tidak ada subtitle yang bisa dibaca dari file ini."; return }
            addCaptions(cues)
        } catch {
            statusMessage = "Gagal membaca SRT: \(error.localizedDescription)"
        }
    }

    var captionCues: [CaptionCue] {
        rootClips.filter { $0.title?.isCaption == true }
            .sorted { $0.startTime < $1.startTime }
            .map { CaptionCue(start: $0.startTime, end: $0.endTime, text: $0.title?.text ?? "") }
    }

    func exportSRT() {
        let cues = captionCues
        guard !cues.isEmpty else { statusMessage = "Belum ada caption (judul bertipe Subtitle) di timeline."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "Captions.srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SRT.write(cues).write(to: url, atomically: true, encoding: .utf8) }
        catch { statusMessage = "Gagal menyimpan SRT: \(error.localizedDescription)" }
    }

    /// Auto-caption dari audio klip terpilih memakai Apple Speech.
    func generateCaptions(for id: UUID?, locale: Locale = .current) async {
        guard let id, let clip = clip(id), clip.asset.isEditable, clip.asset.hasAudio else {
            statusMessage = "Pilih klip yang punya audio untuk dibuatkan caption."
            return
        }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let words = try await TranscriptionService.transcribe(url: clip.asset.url, locale: locale)
            let lo = clip.offsetInAsset, hi = clip.offsetInAsset + clip.sourceSpan
            let inside = words.filter { $0.start + $0.duration > lo && $0.start < hi }
            let cues = TranscriptionService.cues(from: inside).map {
                CaptionCue(start: max($0.start, lo), end: min($0.end, hi), text: $0.text)
            }
            // waktu media → waktu timeline (memperhitungkan kecepatan klip)
            if clip.isRetimed {
                addCaptions(cues.map { CaptionCue(start: clip.timelineTime(forSource: $0.start), end: clip.timelineTime(forSource: $0.end), text: $0.text) }, timeOffset: 0)
            } else {
                addCaptions(cues, timeOffset: clip.startTime - clip.offsetInAsset)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: Marks

    func setMarkIn() {
        markIn = playhead
        if let out = markOut, out <= playhead { markOut = nil }
    }

    func setMarkOut() {
        markOut = playhead
        if let i = markIn, i >= playhead { markIn = nil }
    }

    func clearMarks() {
        markIn = nil
        markOut = nil
    }

    // MARK: Transport

    func seek(to time: Double) {
        playhead = min(max(0, time), totalDuration)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying { pause(); return }
        guard !clips.isEmpty else { return }
        if playhead >= totalDuration - 0.03 { seek(to: 0) }
        skimTime = nil
        shuttleRate = 1
        isPlaying = true
        player.play()
    }

    /// J / L: putar mundur / maju; tekan lagi untuk 2×, 4×, 8×.
    func shuttle(forward: Bool) {
        guard !clips.isEmpty else { return }
        var rate = forward ? 1.0 : -1.0
        if isPlaying, shuttleRate != 0, (shuttleRate > 0) == forward {
            let index = Self.shuttleSteps.firstIndex(of: abs(shuttleRate)) ?? 0
            rate = (forward ? 1 : -1) * Self.shuttleSteps[min(index + 1, Self.shuttleSteps.count - 1)]
        }
        if rate > 0, playhead >= totalDuration - 0.03 { seek(to: 0) }
        if rate < 0, playhead <= 0.03 { seek(to: totalDuration) }
        skimTime = nil
        shuttleRate = rate
        isPlaying = true
        player.rate = Float(rate)
    }

    func pause() {
        isPlaying = false
        shuttleRate = 0
        player.pause()
    }

    func step(frames: Int) {
        pause()
        seek(to: playhead + Double(frames) / projectFrameRate)
    }

    func jumpToEdit(forward: Bool) {
        let points = Set(clips.flatMap { [$0.startTime, $0.endTime] } + [0]).sorted()
        let target = forward ? points.first { $0 > playhead + 0.02 } : points.last { $0 < playhead - 0.02 }
        seek(to: target ?? (forward ? totalDuration : 0))
    }

    /// Skimming: arahkan pointer di timeline untuk melihat frame tanpa menggeser playhead.
    func skim(to time: Double?) {
        skimTime = time
        guard !isPlaying else { return }
        let t = min(max(0, time ?? playhead), totalDuration)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
    }

    private func tick(_ time: CMTime) {
        guard isPlaying, time.isNumeric else { return }
        playhead = min(max(0, time.seconds), totalDuration)
        if shuttleRate > 0, time.seconds >= totalDuration - 0.02 { pause() }
        if shuttleRate < 0, time.seconds <= 0.02 { pause() }
    }

    // MARK: Player composition

    func scheduleRebuildExternal() { scheduleRebuild() }

    /// Dimatikan oleh harness uji supaya model sementara tidak membuat AVPlayer yang tidak dipakai.
    nonisolated(unsafe) static var autoRebuild = true

    func rebuildNow() async { await rebuildPlayerItem() }

    private func scheduleRebuild() {
        guard Self.autoRebuild else { return }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.rebuildPlayerItem()
        }
    }

    private func rebuildPlayerItem() async {
        let snapshot = clips
        guard !snapshot.isEmpty else {
            pause()
            player.replaceCurrentItem(with: nil)
            return
        }
        let built = await CompositionBuilder.build(clips: snapshot, roleMix: roleMix, useProxies: useProxies, management: colorManagement)
        guard !Task.isCancelled else { return }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioTimePitchAlgorithm = .spectral // pitch tetap saat klip diperlambat/dipercepat
        item.audioMix = built.audioMix
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        scopeOutput = output
        player.replaceCurrentItem(with: item)
        renderSize = built.renderSize
        await player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying { player.rate = Float(shuttleRate == 0 ? 1 : shuttleRate) }
    }

    // MARK: Color

    /// Frame terbaru untuk scope; memakai frame terakhir bila belum ada yang baru (mis. saat berhenti).
    func currentFrameBuffer() -> CVPixelBuffer? {
        guard let output = scopeOutput else { return nil }
        let time = player.currentTime()
        if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) { lastScopeBuffer = buffer }
        return lastScopeBuffer
    }

    func exportCurrentFramePNG() {
        guard let item = player.currentItem, !clips.isEmpty else {
            statusMessage = "Putar atau pilih frame pada timeline terlebih dahulu."
            return
        }
        let time = player.currentTime()
        guard time.isNumeric else {
            statusMessage = "Frame saat ini tidak tersedia untuk diekspor."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "MontaseStudio-Frame.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.videoComposition = item.videoComposition
            generator.appliesPreferredTrackTransform = true
            do {
                let frame = try await generator.image(at: time).image
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, frame, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                statusMessage = "Ekspor frame PNG gagal: \(error.localizedDescription)"
            }
        }
    }

    func pickLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube")!]
        panel.message = "Pilih file LUT (.cube)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyLUT(at: url)
    }

    func applyLUT(at url: URL, to id: UUID? = nil) {
        guard let id = id ?? selectedClipID,
              let target = clip(id), target.asset.fileType == .video || target.isAdjustmentLayer else {
            statusMessage = "Pilih klip video atau adjustment layer di timeline terlebih dulu."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            let lut = try CubeLUT.parse(text, name: url.deletingPathExtension().lastPathComponent)
            checkpoint()
            updateClip(id) { $0.grade.lut = lut }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: Export

    func presentExportFCPXML() {
        guard !clips.isEmpty else {
            statusMessage = "Timeline kosong, tidak ada yang bisa diekspor."
            return
        }
        if CompositionBuilder.flatten(clips).contains(where: { $0.clip.asset.fileType == .adjustment || $0.clip.backgroundRemoval == true }) {
            statusMessage = "FCPXML tidak dapat mempertahankan adjustment layer atau penghapusan latar. Hapus efek tersebut atau gunakan export video."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml")!]
        panel.nameFieldStringValue = "KHCutPro Project.fcpxml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FCPXMLExporter.xml(clips: clips, projectName: url.deletingPathExtension().lastPathComponent)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "Export FCPXML gagal: \(error.localizedDescription)"
        }
    }

    func presentExport() {
        guard !clips.isEmpty else {
            statusMessage = "Timeline kosong, tidak ada yang bisa diekspor."
            return
        }
        isExportSheetPresented = true
    }

    /// Batch export: tiap preset diekspor berurutan ke folder yang dipilih.
    func runExport(presets: [ExportPreset], baseName: String, range: ClosedRange<Double>?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Pilih Folder"
        panel.message = "Pilih folder tujuan export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let snapshot = clips
        let mix = roleMix
        let managed = colorManagement
        pause()
        isExporting = true
        Task {
            defer { isExporting = false; exportProgress = 0; exportStatus = "" }
            var done: [URL] = []
            for (index, preset) in presets.enumerated() {
                let url = folder.appendingPathComponent("\(baseName) - \(preset.shortName).\(preset.fileExtension)")
                exportStatus = "\(index + 1)/\(presets.count): \(preset.title)"
                exportProgress = 0
                do {
                    try await ExportEngine.run(clips: snapshot, roleMix: mix, management: managed, preset: preset, to: url, range: range) { [weak self] value in
                        Task { @MainActor in self?.exportProgress = value }
                    }
                    done.append(url)
                } catch {
                    statusMessage = "Export \(preset.title) gagal: \(error.localizedDescription)"
                    break
                }
            }
            if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
        }
    }
}

// MARK: - Composition builder

enum CompositionBuilder {
    struct Result {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition?
        var audioMix: AVMutableAudioMix?
        var renderSize = CGSize(width: 1920, height: 1080)
    }

    private struct Placement {
        var track: AVMutableCompositionTrack?
        var start: Double
        var end: Double
        var lane: Int
        var params: RenderParams
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private static func orientedRect(of track: AVAssetTrack) async -> (CGRect, CGAffineTransform)? {
        guard let info = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: info.0).applying(info.1)
        return (rect, info.1)
    }

    private static func stillImage(_ asset: MediaAsset, renderSize: CGSize) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(renderSize.width / extent.width, renderSize.height / extent.height)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (renderSize.width - scaled.extent.width) / 2,
            y: (renderSize.height - scaled.extent.height) / 2))
        let bounds = CGRect(origin: .zero, size: renderSize)
        return centered.composited(over: CIImage(color: .clear).cropped(to: bounds)).cropped(to: bounds)
    }

    /// Membuka compound clip dan multicam menjadi daftar klip media biasa dengan waktu absolut.
    static func flatten(_ clips: [TimelineClip]) -> [FlatClip] {
        clips.flatMap { expand($0, layer: $0.lane) }
    }

    private static func expand(_ clip: TimelineClip, layer: Int) -> [FlatClip] {
        if let mc = clip.multicam {
            func piece(_ index: Int, video: Bool, audio: Bool) -> FlatClip? {
                guard mc.angles.indices.contains(index) else { return nil }
                let angle = mc.angles[index]
                var c = clip
                c.asset = angle.asset
                c.multicam = nil
                var mediaOffset = clip.offsetInAsset - angle.start
                var start = clip.startTime
                var duration = clip.duration
                if mediaOffset < 0 { // angle belum mulai pada saat ini: potongan awal dilewati
                    start -= mediaOffset
                    duration += mediaOffset
                    mediaOffset = 0
                }
                if angle.asset.duration > 0 { duration = min(duration, angle.asset.duration - mediaOffset) }
                guard duration > 0.01 else { return nil }
                c.startTime = start
                c.duration = duration
                c.offsetInAsset = mediaOffset
                return FlatClip(clip: c, layer: layer, useVideo: video, useAudio: audio)
            }
            if mc.activeVideo == mc.activeAudio {
                return [piece(mc.activeVideo, video: true, audio: true)].compactMap { $0 }
            }
            return [piece(mc.activeVideo, video: true, audio: false), piece(mc.activeAudio, video: false, audio: true)].compactMap { $0 }
        }
        if clip.isCompound {
            return clip.windowedChildren().flatMap { expand($0, layer: layer * 100 + $0.lane) }
        }
        return [FlatClip(clip: clip, layer: layer)]
    }

    /// Volume klip: nilai statis, fade in/out, atau kurva keyframe (dicuplik menjadi ramp linear pendek).
    private static func addVolume(_ params: AVMutableAudioMixInputParameters, for clip: TimelineClip, roleGain: Float) {
        let start = clip.startTime, duration = clip.duration
        let fadeIn = min(max(max(clip.fadeIn, clip.transitionOverlap), 0), duration)
        let fadeOut = min(max(max(clip.fadeOut, clip.transitionOutOverlap), 0), duration - fadeIn)
        func gain(_ db: Double) -> Float { clip.isMuted ? 0 : Float(pow(10, db / 20)) * roleGain }

        if let track = clip.tracks[.volume], !track.isEmpty {
            let step = max(0.05, duration / 2000)
            var previous: (t: Double, g: Float)?
            var t = 0.0
            while true {
                let tt = min(t, duration)
                var g = gain(track.value(at: clip.offsetInAsset + tt) ?? 0)
                if fadeIn > 0 { g *= Float(min(1, tt / fadeIn)) }
                if fadeOut > 0 { g *= Float(min(1, (duration - tt) / fadeOut)) }
                if let previous {
                    params.setVolumeRamp(fromStartVolume: previous.g, toEndVolume: g,
                                         timeRange: CMTimeRange(start: time(start + previous.t), end: time(start + tt)))
                } else {
                    params.setVolume(g, at: time(start))
                }
                previous = (tt, g)
                if tt >= duration { break }
                t += step
            }
            return
        }

        let g = gain(clip.volumeDB)
        if fadeIn > 0 {
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: g, timeRange: CMTimeRange(start: time(start), duration: time(fadeIn)))
        } else {
            params.setVolume(g, at: time(start))
        }
        if fadeOut > 0 {
            params.setVolumeRamp(fromStartVolume: g, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: time(start + duration - fadeOut), duration: time(fadeOut)))
        }
    }

    /// Mengubah kecepatan potongan media yang baru dimasukkan di ujung track. Potongan diproses dari belakang
    /// supaya posisi potongan yang lebih awal tidak bergeser oleh potongan sebelumnya.
    private static func applyRetime(_ clip: TimelineClip, to track: AVMutableCompositionTrack) {
        guard clip.isRetimed, let retime = clip.retime else { return }
        let pieces = retime.pieces(duration: clip.duration)
        var sourceCursor = 0.0
        var sourceBounds: [CMTime] = [time(clip.startTime)]
        for piece in pieces {
            sourceCursor += piece.source
            sourceBounds.append(time(clip.startTime + sourceCursor))
        }
        for (i, piece) in pieces.enumerated().reversed() {
            let from = CMTimeRange(start: sourceBounds[i], end: sourceBounds[i + 1])
            let target = time(piece.local.upperBound) - time(piece.local.lowerBound)
            guard from.duration > .zero, target > .zero else { continue }
            track.scaleTimeRange(from, toDuration: target)
        }
    }

    static func build(clips: [TimelineClip], roleMix: [AudioRole: RoleMix] = [:], useProxies: Bool = false,
                      management: ColorManagementMode = .off) async -> Result {
        let composition = AVMutableComposition()
        let flat = flatten(clips).sorted { $0.clip.startTime < $1.clip.startTime }

        // Ukuran render mengikuti klip video pertama di primary storyline.
        var renderSize = CGSize(width: 1920, height: 1080)
        if let first = flat.first(where: { $0.layer == 0 && $0.clip.asset.fileType == .video }),
           let track = (try? await AVURLAsset(url: first.clip.asset.playbackURL(useProxy: useProxies)).loadTracks(withMediaType: .video))?.first,
           let (rect, _) = await orientedRect(of: track) {
            renderSize = CGSize(width: (abs(rect.width) / 2).rounded() * 2, height: (abs(rect.height) / 2).rounded() * 2)
        }

        var videoTracks: [(track: AVMutableCompositionTrack, end: Double)] = []
        var audioTracks: [(track: AVMutableCompositionTrack, end: Double, params: AVMutableAudioMixInputParameters, fx: AudioFX?)] = []
        var placements: [Placement] = []

        for item in flat {
            let clip = item.clip
            if clip.isAdjustmentLayer {
                placements.append(Placement(
                    track: nil, start: clip.startTime, end: clip.endTime, lane: item.layer,
                    params: RenderParams(base: .identity, clipStart: clip.startTime, mediaOffset: 0,
                                         values: clip.renderValues, tracks: clip.tracks, blend: clip.blend,
                                         grades: clip.nodes.filter(\.enabled).map(\.grade),
                                         isAdjustmentLayer: true, clipDuration: clip.duration)))
                continue
            }
            if clip.asset.fileType == .image {
                guard let image = stillImage(clip.asset, renderSize: renderSize) else {
                    continue
                }
                placements.append(Placement(
                    track: nil, start: clip.startTime, end: clip.endTime, lane: item.layer,
                    params: RenderParams(base: .identity, clipStart: clip.startTime, mediaOffset: 0,
                                         values: clip.renderValues, tracks: clip.tracks, blend: clip.blend,
                                         grades: clip.nodes.filter(\.enabled).map(\.grade),
                                         titleImage: TitleImage(image: image),
                                         fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, clipDuration: clip.duration)))
                continue
            }
            if let spec = clip.title {
                // Judul tidak punya track media; digambar compositor dari gambar teks yang dirender di sini.
                guard let image = TextRenderer.image(for: spec, size: renderSize) else { continue }
                placements.append(Placement(
                    track: nil, start: clip.startTime, end: clip.endTime, lane: item.layer,
                    params: RenderParams(base: .identity, clipStart: clip.startTime, mediaOffset: 0, values: clip.renderValues,
                                         tracks: clip.tracks, blend: clip.blend, grades: [], titleImage: image,
                                         fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, clipDuration: clip.duration)))
                continue
            }
            let asset = AVURLAsset(url: clip.asset.playbackURL(useProxy: useProxies))
            let range = CMTimeRange(start: time(clip.offsetInAsset), duration: time(clip.sourceSpan))
            let at = time(clip.startTime)

            if item.useVideo, clip.asset.fileType == .video,
               let source = (try? await asset.loadTracks(withMediaType: .video))?.first {
                var index = videoTracks.firstIndex { $0.end <= clip.startTime + 0.0005 }
                if index == nil, let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    videoTracks.append((t, 0))
                    index = videoTracks.count - 1
                }
                if let index, (try? videoTracks[index].track.insertTimeRange(range, of: source, at: at)) != nil {
                    applyRetime(clip, to: videoTracks[index].track)
                    videoTracks[index].end = clip.endTime
                    var base = CGAffineTransform.identity
                    if let (rect, preferred) = await orientedRect(of: source), rect.width > 0, rect.height > 0 {
                        let fit = min(renderSize.width / rect.width, renderSize.height / rect.height)
                        base = preferred
                            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
                            .concatenating(CGAffineTransform(translationX: (renderSize.width - rect.width * fit) / 2,
                                                             y: (renderSize.height - rect.height * fit) / 2))
                    }
                    placements.append(Placement(
                        track: videoTracks[index].track, start: clip.startTime, end: clip.endTime, lane: item.layer,
                        params: RenderParams(base: base, clipStart: clip.startTime, mediaOffset: clip.offsetInAsset,
                                             values: clip.renderValues, tracks: clip.tracks, blend: clip.blend, grades: clip.nodes.filter(\.enabled).map(\.grade), keyer: clip.keyer,
                                             removeBackground: clip.backgroundRemoval == true, mask: clip.mask,
                                             inputSpace: clip.inputSpace, management: management,
                                             transition: clip.transition, transitionDuration: clip.transitionOverlap,
                                             clipDuration: clip.duration)))
                }
            }

            if item.useAudio, let source = (try? await asset.loadTracks(withMediaType: .audio))?.first {
                // Track audio dibagi per pengaturan efek, karena efek dijalankan per track.
                let activeFX: AudioFX? = clip.fx.isActive ? clip.fx : nil
                var index = audioTracks.firstIndex { $0.end <= clip.startTime + 0.0005 && $0.fx == activeFX }
                if index == nil, let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let params = AVMutableAudioMixInputParameters(track: t)
                    if let fx = activeFX, let tap = FXTap.make(fx) { params.audioTapProcessor = tap }
                    audioTracks.append((t, 0, params, activeFX))
                    index = audioTracks.count - 1
                }
                if let index, (try? audioTracks[index].track.insertTimeRange(range, of: source, at: at)) != nil {
                    applyRetime(clip, to: audioTracks[index].track)
                    audioTracks[index].end = clip.endTime
                    addVolume(audioTracks[index].params, for: clip, roleGain: RoleGain.linear(clip.role, in: roleMix))
                }
            }
        }

        var result = Result(composition: composition, renderSize: renderSize)
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map(\.params)
            result.audioMix = mix
        }
        guard !placements.isEmpty else { return result }

        // Judul yang melewati ujung media memperpanjang komposisi dengan media hitam pengisi.
        let overall = placements.map(\.end).max() ?? 0
        let mediaEnd = composition.duration.seconds
        if overall > mediaEnd + 0.001, let blank = await BlankMedia.url() {
            let blankAsset = AVURLAsset(url: blank) // harus tetap hidup selama track-nya dipakai
            if let source = (try? await blankAsset.loadTracks(withMediaType: .video))?.first,
               (try? await source.load(.timeRange, .formatDescriptions)) != nil,
               let filler = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var cursor = mediaEnd
                while cursor < overall - 0.0005 {
                    let length = min(1.0, overall - cursor)
                    try? filler.insertTimeRange(CMTimeRange(start: .zero, duration: time(length)), of: source, at: time(cursor))
                    cursor += length
                }
            }
            withExtendedLifetime(blankAsset) {}
        }

        // Satu instruction per segmen waktu; klip di lane lebih tinggi digambar paling atas.
        let total = composition.duration.seconds
        var cuts: Set<Double> = [0, total]
        for p in placements {
            cuts.insert(min(p.start, total))
            cuts.insert(min(p.end, total))
        }
        let ordered = cuts.sorted()
        var times = ordered.map(time)
        times[0] = .zero
        times[times.count - 1] = composition.duration

        var instructions: [GradeInstruction] = []
        for i in 0..<(ordered.count - 1) where ordered[i + 1] - ordered[i] > 0.0005 {
            let a = ordered[i], b = ordered[i + 1]
            let layers = placements
                .filter { $0.start <= a + 0.0005 && $0.end >= b - 0.0005 }
                .sorted { ($0.lane, $0.start) > ($1.lane, $1.start) } // lane tinggi di atas; klip yang lebih baru di atas
                .map { GradeInstruction.Layer(trackID: $0.track?.trackID, params: $0.params) }
            instructions.append(GradeInstruction(timeRange: CMTimeRange(start: times[i], end: times[i + 1]), layers: layers))
        }

        let video = AVMutableVideoComposition()
        video.renderSize = renderSize
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(projectFrameRate))
        video.instructions = instructions
        video.customVideoCompositorClass = GradeCompositor.self
        result.videoComposition = video
        return result
    }
}
