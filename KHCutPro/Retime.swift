import Foundation

/// Titik kecepatan pada kurva speed ramp. `time` dalam detik timeline relatif terhadap awal klip.
nonisolated struct SpeedKey: Sendable, Codable, Equatable {
    var time: Double
    var speed: Double
}

/// Pengaturan kecepatan klip: kecepatan konstan, atau kurva speed ramp (interpolasi linear antar titik, ditahan di kedua ujung).
nonisolated struct Retime: Sendable, Codable, Equatable {
    static let speedRange = 0.05...16.0
    static let minimumDuration = 0.1

    var speed = 1.0
    var keys: [SpeedKey] = []

    var isIdentity: Bool { keys.isEmpty && abs(speed - 1) < 0.0001 }
    var isRamp: Bool { !keys.isEmpty }

    static func clamp(_ value: Double) -> Double { min(max(value, speedRange.lowerBound), speedRange.upperBound) }

    private var sortedKeys: [SpeedKey] { keys.sorted { $0.time < $1.time } }

    /// Kecepatan (1 = normal) pada waktu lokal `t`.
    func speed(at t: Double) -> Double {
        let ks = sortedKeys
        guard let first = ks.first, let last = ks.last else { return Self.clamp(speed) }
        if t <= first.time { return Self.clamp(first.speed) }
        if t >= last.time { return Self.clamp(last.speed) }
        for i in 1..<ks.count where t <= ks[i].time {
            let a = ks[i - 1], b = ks[i]
            let span = b.time - a.time
            let f = span > 0 ? (t - a.time) / span : 1
            return Self.clamp(a.speed + (b.speed - a.speed) * f)
        }
        return Self.clamp(last.speed)
    }

    /// Panjang media sumber (detik) yang terpakai dari waktu lokal 0 sampai `t`. Integral eksak dari kurva kecepatan.
    func span(_ t: Double) -> Double {
        if t < 0 { return speed(at: 0) * t }
        guard !keys.isEmpty else { return Self.clamp(speed) * t }
        var total = 0.0, cursor = 0.0
        var v0 = speed(at: 0)
        for p in sortedKeys.map(\.time).filter({ $0 > 0 && $0 < t }) + [t] {
            let v1 = speed(at: p)
            total += (v0 + v1) / 2 * (p - cursor) // linear di antara dua titik henti, jadi trapesium tepat
            cursor = p
            v0 = v1
        }
        return total
    }

    /// Kebalikan dari `span`: waktu lokal yang mengonsumsi `source` detik media.
    func local(forSpan source: Double) -> Double {
        let bound = abs(source) / Self.speedRange.lowerBound + 1
        var lo = -bound, hi = bound
        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            if span(mid) < source { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Retime untuk potongan kanan setelah klip dibelah di waktu lokal `d`.
    func rightPart(at d: Double) -> Retime {
        guard !keys.isEmpty else { return self }
        var out = self
        out.keys = [SpeedKey(time: 0, speed: speed(at: d))] + sortedKeys.filter { $0.time > d + 0.0001 }.map { SpeedKey(time: $0.time - d, speed: $0.speed) }
        return out
    }

    /// Retime untuk potongan kiri setelah klip dibelah di waktu lokal `d`.
    func leftPart(at d: Double) -> Retime {
        guard !keys.isEmpty else { return self }
        var out = self
        out.keys = sortedKeys.filter { $0.time < d - 0.0001 } + [SpeedKey(time: d, speed: speed(at: d))]
        return out
    }

    /// Potongan-potongan komposisi: tiap potongan berkecepatan konstan. Kurva dipecah tiap ~0.2 detik supaya ramp terasa mulus.
    func pieces(duration: Double) -> [(local: ClosedRange<Double>, source: Double)] {
        guard duration > 0 else { return [] }
        var marks: [Double] = [0, duration]
        let inner = sortedKeys.map(\.time).filter { $0 > 0.001 && $0 < duration - 0.001 }
        marks += inner
        marks.sort()
        var bounds: [Double] = []
        for i in 0..<(marks.count - 1) {
            let a = marks[i], b = marks[i + 1]
            let rampy = keys.isEmpty ? 1 : max(1, Int((b - a) / 0.2))
            for n in 0..<rampy { bounds.append(a + (b - a) * Double(n) / Double(rampy)) }
        }
        bounds.append(duration)
        return (0..<(bounds.count - 1)).map { i in
            (bounds[i]...bounds[i + 1], span(bounds[i + 1]) - span(bounds[i]))
        }
    }

    /// Kurva siap pakai. Titik-titik dinyatakan sebagai pecahan dari durasi keluaran sehingga bentuknya tetap saat durasi berubah.
    enum Preset: String, CaseIterable, Identifiable {
        case normal, slow50, slow25, fast2, fast4, rampSlow, rampFast, hero, flash
        var id: String { rawValue }

        var title: String {
            switch self {
            case .normal: "Normal (1×)"
            case .slow50: "Slow-mo 50%"
            case .slow25: "Slow-mo 25%"
            case .fast2: "Cepat 2×"
            case .fast4: "Cepat 4×"
            case .rampSlow: "Ramp: normal → lambat"
            case .rampFast: "Ramp: lambat → cepat"
            case .hero: "Hero (cepat → lambat → cepat)"
            case .flash: "Flash (lambat → cepat → normal)"
            }
        }

        var constant: Double? {
            switch self {
            case .normal: 1
            case .slow50: 0.5
            case .slow25: 0.25
            case .fast2: 2
            case .fast4: 4
            default: nil
            }
        }

        /// (pecahan durasi, kecepatan)
        var shape: [(Double, Double)] {
            switch self {
            case .rampSlow: [(0, 1), (0.5, 1), (1, 0.25)]
            case .rampFast: [(0, 0.25), (0.5, 0.25), (1, 4)]
            case .hero: [(0, 3), (0.3, 3), (0.45, 0.25), (0.65, 0.25), (0.8, 3), (1, 3)]
            case .flash: [(0, 0.3), (0.4, 0.3), (0.6, 3), (1, 1)]
            default: []
            }
        }
    }
}

extension TimelineClip {
    /// Klip yang boleh diubah kecepatannya: media video/audio biasa (bukan judul, adjustment, compound, atau multicam).
    var canRetime: Bool {
        !isContainer && !isAdjustmentLayer && !isTitle && (asset.fileType == .video || asset.fileType == .audio)
    }

    var isRetimed: Bool { !(retime?.isIdentity ?? true) }

    /// Panjang media sumber yang dipakai klip ini.
    var sourceSpan: Double { isRetimed ? (retime?.span(duration) ?? duration) : duration }

    /// Media yang dikonsumsi `local` detik pertama (atau terakhir bila negatif) klip.
    func sourceDelta(forLocal local: Double) -> Double { isRetimed ? (retime?.span(local) ?? local) : local }

    /// Detik timeline yang dibutuhkan untuk `source` detik media dari awal klip.
    func localDelta(forSource source: Double) -> Double { isRetimed ? (retime?.local(forSpan: source) ?? source) : source }

    /// Posisi timeline untuk waktu media `s`.
    func timelineTime(forSource s: Double) -> Double { startTime + localDelta(forSource: s - offsetInAsset) }

    /// Memotong kepala klip sebesar `delta` detik timeline (negatif = memanjang). Durasi tidak diubah di sini.
    mutating func trimHead(by delta: Double) {
        let source = sourceDelta(forLocal: delta)
        offsetInAsset += source
        if isRetimed, var r = retime {
            if delta > 0 { r = r.rightPart(at: delta) }
            else if !r.keys.isEmpty { r.keys = r.keys.map { SpeedKey(time: $0.time - delta, speed: $0.speed) } }
            retime = r
            // Keyframe memakai waktu "offset + waktu lokal"; geser agar tetap menempel pada isi klip.
            let drift = source - delta
            if abs(drift) > 1e-9 {
                for p in tracks.keys { tracks[p]?.keys.indices.forEach { tracks[p]?.keys[$0].time += drift } }
            }
        }
    }

    /// Membelah klip di waktu lokal `d`; mengembalikan potongan kanan (id belum diganti).
    mutating func splitOff(at d: Double) -> TimelineClip {
        var right = self
        let leftRetime = retime?.leftPart(at: d)
        right.trimHead(by: d)
        right.duration = duration - d
        if isRetimed { retime = leftRetime }
        duration = d
        return right
    }

    /// Menetapkan kecepatan baru dengan mempertahankan potongan media yang sama, sehingga durasi klip berubah.
    mutating func applyRetime(_ new: Retime?) {
        let span = sourceSpan
        let normalized = (new?.isIdentity ?? true) ? nil : new
        retime = normalized
        duration = max(Retime.minimumDuration, normalized?.local(forSpan: span) ?? span)
    }

    /// Menerapkan kurva preset; titik-titik diskalakan dengan durasi hasil akhir (iterasi sampai konvergen).
    mutating func applyPreset(_ preset: Retime.Preset) {
        if let constant = preset.constant {
            applyRetime(Retime(speed: constant))
            return
        }
        let span = sourceSpan
        var d = duration
        var result = Retime()
        for _ in 0..<12 {
            result = Retime(speed: 1, keys: preset.shape.map { SpeedKey(time: $0.0 * d, speed: $0.1) })
            d = max(Retime.minimumDuration, result.local(forSpan: span))
        }
        result.keys = preset.shape.map { SpeedKey(time: $0.0 * d, speed: $0.1) }
        applyRetime(result)
    }

    /// Ruang geser kepala (detik timeline, ≤ 0) sebelum menembus awal media.
    var headRoom: Double { localDelta(forSource: -offsetInAsset) }

    /// Ruang perpanjangan ekor (detik timeline, ≥ 0 bila masih ada media) sebelum menembus akhir media.
    var tailRoom: Double {
        guard asset.duration > 0 else { return .infinity }
        let room = asset.duration - offsetInAsset - sourceSpan
        return localDelta(forSource: sourceSpan + room) - duration
    }
}
