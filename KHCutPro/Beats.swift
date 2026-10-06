import Foundation

nonisolated struct BeatResult: Sendable {
    var bpm: Double
    var beats: [Double]   // detik, waktu media
}

/// Deteksi tempo dan beat dari audio: novelty energi → autokorelasi untuk tempo → pencarian fase → penyesuaian ke onset terdekat.
nonisolated enum BeatDetector {
    @concurrent
    static func detect(url: URL, maxSeconds: Double = 300) async -> BeatResult? {
        guard let env = await AudioSync.envelope(url: url, maxSeconds: maxSeconds) else { return nil }
        return analyze(envelope: env, rate: AudioSync.envelopeRate)
    }

    static func analyze(envelope env: [Float], rate: Double) -> BeatResult? {
        guard env.count > Int(rate * 4) else { return nil }

        // Novelty: kenaikan energi (half-wave rectified).
        var novelty = [Float](repeating: 0, count: env.count)
        for i in 1..<env.count { novelty[i] = max(0, env[i] - env[i - 1]) }
        let mean = novelty.reduce(0, +) / Float(novelty.count)
        for i in novelty.indices { novelty[i] = max(0, novelty[i] - mean * 0.5) }

        // Tempo: autokorelasi pada lag 60–200 BPM, dengan prior ringan di sekitar 120 BPM untuk menghindari oktaf yang salah.
        let minLag = Int(rate * 60 / 200), maxLag = Int(rate * 60 / 60)
        var acf = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in 0..<(novelty.count - lag) { sum += Double(novelty[i] * novelty[i + lag]) }
            acf[lag] = sum / Double(novelty.count - lag)
        }
        var bestLag = minLag, bestScore = -1.0
        for lag in (minLag + 1)..<maxLag {
            let bpm = 60 * rate / Double(lag)
            let prior = exp(-pow(log2(bpm / 120), 2) / 2)
            let score = acf[lag] * (0.6 + 0.4 * prior)
            if score > bestScore, acf[lag] >= acf[lag - 1], acf[lag] >= acf[lag + 1] { bestScore = score; bestLag = lag }
        }
        guard bestScore > 0 else { return nil }
        // Interpolasi parabola untuk lag pecahan.
        let y0 = acf[bestLag - 1], y1 = acf[bestLag], y2 = acf[bestLag + 1]
        let denom = y0 - 2 * y1 + y2
        let period = Double(bestLag) + (abs(denom) > 1e-12 ? 0.5 * (y0 - y2) / denom : 0)

        // Fase: posisi awal yang memaksimalkan total novelty di sepanjang kisi beat.
        var bestPhase = 0.0, bestPhaseScore = -1.0
        var phase = 0.0
        while phase < period {
            var sum: Float = 0
            var pos = phase
            while Int(pos.rounded()) < novelty.count { sum += novelty[Int(pos.rounded())]; pos += period }
            if Double(sum) > bestPhaseScore { bestPhaseScore = Double(sum); bestPhase = phase }
            phase += 0.5
        }

        // Rapatkan tiap beat ke puncak onset terdekat (±15% periode) supaya tempo yang sedikit meleset tidak melenceng.
        var beats: [Double] = []
        var pos = bestPhase
        let window = max(1, Int(period * 0.15))
        while Int(pos.rounded()) < novelty.count {
            let center = Int(pos.rounded())
            var peak = center
            for i in max(0, center - window)...min(novelty.count - 1, center + window) where novelty[i] > novelty[peak] { peak = i }
            beats.append(Double(peak) / rate)
            pos += period
        }
        return BeatResult(bpm: 60 * rate / period, beats: beats)
    }
}

struct TimelineMarker: Identifiable, Codable, Equatable {
    var id = UUID()
    var time: Double
    var name: String
    var isBeat = false
}

extension TimelineModel {
    func addMarker(at time: Double? = nil, name: String = "Marker") {
        let t = time ?? playhead
        guard !markers.contains(where: { abs($0.time - t) < 0.02 }) else { return }
        markers.append(TimelineMarker(time: t, name: name))
        markers.sort { $0.time < $1.time }
    }

    func removeMarker(_ id: UUID) { markers.removeAll { $0.id == id } }

    func clearBeatMarkers() { markers.removeAll { $0.isBeat } }

    func jumpToMarker(forward: Bool) {
        let times = markers.map(\.time).sorted()
        let target = forward ? times.first { $0 > playhead + 0.02 } : times.last { $0 < playhead - 0.02 }
        if let target { seek(to: target) }
    }

    /// Deteksi beat dari klip audio/musik terpilih dan tandai di timeline.
    func markBeats(of id: UUID?) async {
        guard let id, let clip = clip(id), clip.asset.isEditable, clip.asset.hasAudio || clip.asset.fileType == .audio else {
            statusMessage = "Pilih klip musik (atau klip dengan audio) untuk dideteksi beat-nya."
            return
        }
        isAnalyzing = true
        analysisStatus = "Mendeteksi beat…"
        defer { isAnalyzing = false; analysisStatus = "" }
        guard let result = await BeatDetector.detect(url: clip.asset.url) else {
            statusMessage = "Beat tidak terdeteksi (audio terlalu pendek atau tanpa ritme jelas)."
            return
        }
        clearBeatMarkers()
        let lo = clip.offsetInAsset, hi = clip.offsetInAsset + clip.duration
        for b in result.beats where b >= lo - 0.001 && b <= hi {
            markers.append(TimelineMarker(time: clip.startTime + (b - clip.offsetInAsset), name: "Beat", isBeat: true))
        }
        markers.sort { $0.time < $1.time }
        detectedBPM = result.bpm
        statusMessage = String(format: "Tempo terdeteksi: %.1f BPM (%d beat ditandai).", result.bpm, markers.filter(\.isBeat).count)
    }

    /// Potong klip primary terpilih (atau semua) supaya setiap titik potong jatuh tepat di beat.
    func cutToBeats(minimumLength: Double = 0.4) {
        let beats = markers.filter(\.isBeat).map(\.time).sorted()
        guard beats.count > 1 else { statusMessage = "Tandai beat dulu dari klip musik (Audio > Tandai Beat)."; return }
        let order = clips.filter { $0.lane == 0 && !$0.isTitle && (selectedClipIDs.isEmpty || selectedClipIDs.contains($0.id)) }
            .sorted { $0.startTime < $1.startTime }
        guard order.count > 1 else { statusMessage = "Pilih dua klip primary atau lebih untuk dipotong mengikuti beat."; return }

        checkpoint()
        // Klip pertama dimulai di beat terdekat dengan awalnya; tiap klip berikutnya berakhir di beat terdekat dari akhir alaminya.
        for (n, original) in order.enumerated() {
            guard let i = clips.firstIndex(where: { $0.id == original.id }) else { continue }
            let start = clips[i].startTime
            let natural = start + clips[i].duration
            guard n < order.count - 1, let target = beats.filter({ $0 > start + minimumLength }).min(by: { abs($0 - natural) < abs($1 - natural) }) else { continue }
            let room = clips[i].asset.duration > 0 ? clips[i].asset.duration - clips[i].offsetInAsset : .infinity
            clips[i].duration = min(max(target - start, minimumLength), room)
            reflowForBeats()
        }
        commit()
    }
}
