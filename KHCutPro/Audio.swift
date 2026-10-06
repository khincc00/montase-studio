import AVFoundation
import Observation

// MARK: - Roles

/// Peran audio: tiap peran punya fader, mute, dan solo sendiri, dan klip audio otomatis ditempatkan di lane peran-nya.
nonisolated enum AudioRole: String, CaseIterable, Sendable, Codable {
    case dialogue, music, effects

    var title: String {
        switch self {
        case .dialogue: "Dialog"
        case .music: "Musik"
        case .effects: "Efek"
        }
    }

    /// Lane audio di bawah storyline: A1 dialog, A2 musik, A3 efek.
    var lane: Int {
        switch self {
        case .dialogue: -1
        case .music: -2
        case .effects: -3
        }
    }

    var laneLabel: String {
        switch self {
        case .dialogue: "A1 · Dialog"
        case .music: "A2 · Musik"
        case .effects: "A3 · Efek"
        }
    }

    /// Tebakan peran dari nama file dan durasinya (bisa diubah di Inspector).
    static func guess(for asset: MediaAsset) -> AudioRole {
        let name = asset.fileName.lowercased()
        if ["music", "musik", "bgm", "song", "lagu", "score", "soundtrack", "theme"].contains(where: name.contains) { return .music }
        if ["sfx", "fx", "whoosh", "hit", "foley", "impact", "swish", "click", "ambience", "ambient"].contains(where: name.contains) { return .effects }
        if asset.fileType == .audio, asset.duration > 90 { return .music }
        return .dialogue
    }
}

nonisolated struct RoleMix: Sendable, Codable, Equatable {
    var volumeDB = 0.0
    var muted = false
    var solo = false
}

nonisolated enum RoleGain {
    /// Penguatan linear untuk satu peran; bila ada peran yang di-solo, peran lain dibisukan.
    static func linear(_ role: AudioRole, in mix: [AudioRole: RoleMix]) -> Float {
        let anySolo = mix.values.contains { $0.solo }
        let m = mix[role] ?? RoleMix()
        if m.muted || (anySolo && !m.solo) { return 0 }
        return Float(pow(10, m.volumeDB / 20))
    }
}

// MARK: - Waveform

/// Puncak amplitudo per 50 ms untuk tiap media; dipakai untuk menggambar waveform, meter, dan auto-ducking.
@MainActor
@Observable
final class WaveformCache {
    static let shared = WaveformCache()
    static let hopSeconds = 0.05

    private(set) var peaks: [UUID: [Float]] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []

    func ensure(_ asset: MediaAsset) async {
        guard asset.hasAudio || asset.fileType == .audio, peaks[asset.id] == nil, !loading.contains(asset.id) else { return }
        loading.insert(asset.id)
        let result = await Self.readPeaks(url: asset.url)
        loading.remove(asset.id)
        peaks[asset.id] = result ?? []
    }

    func set(_ id: UUID, _ values: [Float]) { peaks[id] = values }

    /// Puncak terbesar di sekitar waktu media `t` (±1 hop).
    func peak(_ id: UUID, at t: Double) -> Float {
        guard let p = peaks[id], !p.isEmpty else { return 0 }
        let i = Int(t / Self.hopSeconds)
        guard i >= -1, i <= p.count else { return 0 }
        return max(p[min(max(i - 1, 0), p.count - 1)], p[min(max(i, 0), p.count - 1)], p[min(max(i + 1, 0), p.count - 1)])
    }

    @concurrent
    static func readPeaks(url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let hop = Int(8000 * hopSeconds)
        var result: [Float] = []
        var current: Int16 = 0, count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var pcm = [Int16](repeating: 0, count: length / 2)
            guard pcm.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == kCMBlockBufferNoErr else { continue }
            for s in pcm {
                current = max(current, s == Int16.min ? Int16.max : abs(s))
                count += 1
                if count == hop { result.append(Float(current) / 32767); current = 0; count = 0 }
            }
        }
        if count > 0 { result.append(Float(current) / 32767) }
        return result
    }
}

// MARK: - Model operations

extension TimelineModel {
    /// Penguatan klip pada waktu timeline `t` (volume, keyframe, fade, transisi, dan peran), linear.
    func audioGain(of clip: TimelineClip, at t: Double) -> Float {
        guard t >= clip.startTime, t <= clip.endTime, !clip.isMuted else { return 0 }
        var g = Float(pow(10, clip.value(.volume, atMedia: clip.mediaTime(at: t)) / 20))
        let local = t - clip.startTime
        let fadeIn = max(clip.fadeIn, clip.transitionOverlap), fadeOut = max(clip.fadeOut, clip.transitionOutOverlap)
        if fadeIn > 0 { g *= Float(min(1, local / fadeIn)) }
        if fadeOut > 0 { g *= Float(min(1, (clip.duration - local) / fadeOut)) }
        return g * RoleGain.linear(clip.role, in: roleMix)
    }

    /// Level meter di posisi `t`: perkiraan dari waveform sumber dikali penguatan, dijumlahkan antar klip.
    func meterLevel(at t: Double) -> Float {
        var total: Float = 0
        for c in CompositionBuilder.flatten(rootClips) where c.useAudio && (c.clip.asset.hasAudio || c.clip.asset.fileType == .audio) {
            let clip = c.clip
            guard t >= clip.startTime, t <= clip.endTime else { continue }
            total += WaveformCache.shared.peak(clip.asset.id, at: clip.mediaTime(at: t)) * audioGain(of: clip, at: t)
        }
        return min(1, total)
    }

    func setRole(_ id: UUID, _ role: AudioRole) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        clips[i].role = role
        if clips[i].asset.fileType == .audio {
            clips[i].lane = role.lane
            avoidCollision(id)
        }
        commit()
    }

    func setRoleMix(_ role: AudioRole, _ change: (inout RoleMix) -> Void) {
        var m = roleMix[role] ?? RoleMix()
        change(&m)
        roleMix[role] = m
        scheduleRebuildExternal()
    }

    /// Musik otomatis mengecil saat ada dialog: membuat keyframe volume pada klip berperan musik.
    func autoDuck(amountDB: Double = -14, threshold: Float = 0.06, attack: Double = 0.25, release: Double = 0.6) async {
        let flat = CompositionBuilder.flatten(rootClips)
        let dialogue = flat.filter { $0.clip.role == .dialogue && ($0.clip.asset.hasAudio || $0.clip.asset.fileType == .audio) && $0.useAudio }
        let music = rootClips.filter { $0.role == .music && !$0.isContainer && ($0.asset.hasAudio || $0.asset.fileType == .audio) }
        guard !music.isEmpty else { statusMessage = "Tidak ada klip berperan Musik. Ubah peran klip musik di Inspector > Audio."; return }
        guard !dialogue.isEmpty else { statusMessage = "Tidak ada klip berperan Dialog untuk dijadikan acuan."; return }
        for d in dialogue { await WaveformCache.shared.ensure(d.clip.asset) }

        // Aktivitas dialog per 50 ms sepanjang timeline.
        let step = WaveformCache.hopSeconds
        let end = totalDuration
        var active = [Bool](repeating: false, count: Int(end / step) + 1)
        for i in active.indices {
            let t = Double(i) * step
            active[i] = dialogue.contains { d in
                t >= d.clip.startTime && t <= d.clip.endTime
                    && WaveformCache.shared.peak(d.clip.asset.id, at: d.clip.mediaTime(at: t)) * audioGain(of: d.clip, at: t) >= threshold
            }
        }
        // Gabungkan jeda pendek (< 0,5 s) agar musik tidak naik-turun di antara kata.
        var intervals: [(Double, Double)] = []
        var i = 0
        while i < active.count {
            guard active[i] else { i += 1; continue }
            var j = i, gap = 0
            while j < active.count, gap < Int(0.5 / step) { if active[j] { gap = 0 } else { gap += 1 }; j += 1 }
            let last = max(i, j - gap - 1)
            intervals.append((Double(i) * step, Double(last + 1) * step))
            i = j
        }

        checkpoint()
        for m in music {
            guard let index = clips.firstIndex(where: { $0.id == m.id }) else { continue }
            let base = m.staticValue(.volume)
            var keys: [Keyframe] = []
            func key(_ timelineTime: Double, _ db: Double) {
                keys.append(Keyframe(time: m.mediaTime(at: min(max(timelineTime, m.startTime), m.endTime)), value: db, easing: .linear))
            }
            key(m.startTime, base)
            for (a, b) in intervals where b > m.startTime && a < m.endTime {
                key(a - attack, base); key(a, base + amountDB)
                key(b, base + amountDB); key(b + release, base)
            }
            key(m.endTime, base)
            var track = KeyframeTrack()
            for k in keys.sorted(by: { $0.time < $1.time }) { track.set(time: k.time, value: k.value); if let i = track.index(near: k.time) { track.keys[i].easing = .linear } }
            clips[index].tracks[.volume] = track
        }
        scheduleRebuildExternal()
    }

    /// Sinkronkan klip audio terpilih ke suara klip video terpilih (mis. audio recorder eksternal).
    func autoSyncAudioToVideo() async {
        let selected = clips.filter { selectedClipIDs.contains($0.id) }
        guard let video = selected.first(where: { $0.asset.fileType == .video && $0.asset.hasAudio }),
              let audio = selected.first(where: { $0.asset.fileType == .audio }) else {
            statusMessage = "Pilih satu klip video (yang punya audio) dan satu klip audio, lalu jalankan Auto-Sync."
            return
        }
        isAnalyzing = true
        analysisStatus = "Menyinkronkan audio…"
        defer { isAnalyzing = false; analysisStatus = "" }
        async let a = AudioSync.envelope(url: video.asset.url, maxSeconds: 180)
        async let b = AudioSync.envelope(url: audio.asset.url, maxSeconds: 180)
        guard let ref = await a, let other = await b, let shift = await AudioSync.offset(reference: ref, other: other) else {
            statusMessage = "Audio tidak bisa disinkronkan: suaranya terlalu berbeda atau terlalu sedikit yang tumpang tindih."
            return
        }
        // media audio mulai `shift` detik setelah media video (waktu media nol); hitung posisi timeline yang menyejajarkan keduanya.
        let start = video.startTime - video.offsetInAsset + shift + audio.offsetInAsset
        checkpoint()
        if let i = clips.firstIndex(where: { $0.id == audio.id }) {
            clips[i].startTime = max(0, start)
            clips[i].anchorID = nil
        }
        commit()
    }
}
