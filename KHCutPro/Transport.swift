import AVFoundation
import Observation

enum MonitorMode { case timeline, source }

struct SourceMarks {
    var markIn: Double?
    var markOut: Double?
}

/// Pemutar untuk klip di Browser (source). Tanda In/Out disimpan per media dan dipakai oleh E/W/Q.
@MainActor
@Observable
final class SourceMonitor {
    private static let shuttleSteps: [Double] = [1, 2, 4, 8]

    var asset: MediaAsset?
    var position = 0.0
    var isPlaying = false
    var shuttleRate = 0.0
    private(set) var marks: [UUID: SourceMarks] = [:]

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var observer: Any?

    init() {
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: CMTimeScale(projectFrameRate)), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    var duration: Double { asset?.duration ?? 0 }
    var currentMarks: SourceMarks { asset.flatMap { marks[$0.id] } ?? SourceMarks() }

    func load(_ asset: MediaAsset) {
        pause()
        self.asset = asset
        position = 0
        player.replaceCurrentItem(with: asset.isEditable ? AVPlayerItem(url: asset.url) : nil)
    }

    func seek(to time: Double) {
        position = min(max(0, time), duration > 0 ? duration : time)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying { pause(); return }
        guard asset?.isEditable == true else { return }
        if duration > 0, position >= duration - 0.03 { seek(to: 0) }
        shuttleRate = 1
        isPlaying = true
        player.play()
    }

    func shuttle(forward: Bool) {
        guard asset?.isEditable == true else { return }
        var rate = forward ? 1.0 : -1.0
        if isPlaying, shuttleRate != 0, (shuttleRate > 0) == forward {
            let index = Self.shuttleSteps.firstIndex(of: abs(shuttleRate)) ?? 0
            rate = (forward ? 1 : -1) * Self.shuttleSteps[min(index + 1, Self.shuttleSteps.count - 1)]
        }
        if rate > 0, duration > 0, position >= duration - 0.03 { seek(to: 0) }
        if rate < 0, position <= 0.03 { seek(to: duration) }
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
        seek(to: position + Double(frames) / projectFrameRate)
    }

    private func tick(_ time: CMTime) {
        guard isPlaying, time.isNumeric else { return }
        position = time.seconds
        if shuttleRate > 0, duration > 0, position >= duration - 0.02 { pause() }
        if shuttleRate < 0, position <= 0.02 { pause() }
    }

    // MARK: In / Out

    func setIn() {
        guard let id = asset?.id else { return }
        var m = marks[id] ?? SourceMarks()
        m.markIn = position
        if let out = m.markOut, out <= position { m.markOut = nil }
        marks[id] = m
    }

    func setOut() {
        guard let id = asset?.id else { return }
        var m = marks[id] ?? SourceMarks()
        m.markOut = position
        if let markIn = m.markIn, markIn >= position { m.markIn = nil }
        marks[id] = m
    }

    func clearMarks() {
        guard let id = asset?.id else { return }
        marks[id] = nil
    }

    /// Rentang yang dipakai saat Append / Insert / Connect; nil bila belum ada tanda In/Out.
    func range(for asset: MediaAsset) -> ClosedRange<Double>? {
        guard let m = marks[asset.id], m.markIn != nil || m.markOut != nil else { return nil }
        let start = m.markIn ?? 0
        let end = m.markOut ?? (asset.duration > 0 ? asset.duration : start + 5)
        return end - start > 0.05 ? start...end : nil
    }
}

enum EditOperation { case append, insert, connect }

/// Mengarahkan perintah transport (play, J-K-L, I/O, E/W/Q) ke monitor yang sedang aktif.
@MainActor
@Observable
final class Transport {
    let timeline: TimelineModel
    let library: MediaLibrary
    let source = SourceMonitor()
    var mode: MonitorMode = .timeline

    init(timeline: TimelineModel, library: MediaLibrary) {
        self.timeline = timeline
        self.library = library
    }

    var usesSource: Bool { mode == .source && source.asset != nil }
    var time: Double { usesSource ? source.position : timeline.playhead }
    var duration: Double { usesSource ? source.duration : timeline.totalDuration }
    var isPlaying: Bool { usesSource ? source.isPlaying : timeline.isPlaying }
    var rate: Double { usesSource ? source.shuttleRate : timeline.shuttleRate }
    var activePlayer: AVPlayer { usesSource ? source.player : timeline.player }

    func showSource(_ asset: MediaAsset) {
        timeline.pause()
        source.load(asset)
        mode = .source
    }

    func showTimeline() {
        guard mode != .timeline else { return }
        source.pause()
        mode = .timeline
    }

    func togglePlay() { usesSource ? source.togglePlay() : timeline.togglePlay() }
    func shuttle(forward: Bool) { usesSource ? source.shuttle(forward: forward) : timeline.shuttle(forward: forward) }
    func pause() { usesSource ? source.pause() : timeline.pause() }
    func step(frames: Int) { usesSource ? source.step(frames: frames) : timeline.step(frames: frames) }

    func seek(to time: Double) {
        if usesSource { source.seek(to: time) } else { timeline.seek(to: time) }
    }

    func goToStart() { pause(); seek(to: 0) }
    func goToEnd() { pause(); seek(to: duration) }

    func markIn() { usesSource ? source.setIn() : timeline.setMarkIn() }
    func markOut() { usesSource ? source.setOut() : timeline.setMarkOut() }
    func clearMarks() { usesSource ? source.clearMarks() : timeline.clearMarks() }

    /// E / W / Q memakai klip terpilih di Browser beserta tanda In/Out-nya (three-point edit).
    func perform(_ operation: EditOperation, asset override: MediaAsset? = nil) {
        guard let asset = override ?? library.selectedAsset else { return }
        let range = source.range(for: asset)
        switch operation {
        case .append: timeline.append(asset, range: range)
        case .insert: timeline.insert(asset, range: range)
        case .connect: timeline.connect(asset, range: range)
        }
    }
}
