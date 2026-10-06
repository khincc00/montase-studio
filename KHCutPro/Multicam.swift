import AVFoundation
import Accelerate

/// Satu multicam clip berisi 2–16 angle yang sudah disejajarkan di satu garis waktu "master".
struct MulticamData: Codable {
    struct Angle: Identifiable, Codable {
        var id = UUID()
        var name: String
        var asset: MediaAsset
        /// Waktu master saat media angle ini mulai. Waktu media = waktu master − start.
        var start: Double
    }

    var angles: [Angle]
    var activeVideo = 0
    var activeAudio = 0
    var contentDuration: Double
}

struct MulticamResult {
    var data: MulticamData
    var unsynced: [String]
}

enum MulticamBuilder {
    static let minAngles = 2
    static let maxAngles = 16

    static func build(from assets: [MediaAsset]) async -> MulticamResult {
        var envelopes: [[Float]?] = []
        for asset in assets { envelopes.append(await AudioSync.envelope(url: asset.url, maxSeconds: 180)) }

        // Acuan sinkron: angle pertama yang punya audio.
        let reference = envelopes.firstIndex { $0 != nil }
        var starts = Array(repeating: 0.0, count: assets.count)
        var unsynced: [String] = []

        for i in assets.indices where i != reference {
            if let r = reference, let ref = envelopes[r], let other = envelopes[i],
               let found = await AudioSync.offset(reference: ref, other: other) {
                starts[i] = starts[r] + found
            } else {
                unsynced.append(assets[i].fileName)
            }
        }
        if reference == nil { unsynced = assets.map(\.fileName) }

        let earliest = starts.min() ?? 0
        let angles = assets.indices.map { i in
            MulticamData.Angle(name: (assets[i].fileName as NSString).deletingPathExtension,
                               asset: assets[i], start: starts[i] - earliest)
        }
        let content = angles.map { $0.start + max($0.asset.duration, 0) }.max() ?? 0
        return MulticamResult(data: MulticamData(angles: angles, contentDuration: content), unsynced: unsynced)
    }
}

/// Sinkronisasi dengan korelasi silang envelope energi audio (200 Hz). Cukup tahan terhadap perbedaan
/// mikrofon dan jarak karena yang dibandingkan adalah pola keras-pelannya, bukan bentuk gelombang.
nonisolated enum AudioSync {
    static let envelopeRate = 200.0
    private static let minScore: Float = 0.25

    /// Membaca audio mono 8 kHz lalu menghitung envelope RMS yang sudah di-high-pass.
    @concurrent
    static func envelope(url: URL, maxSeconds: Double) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1
        ])
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var pcm = [Int16](repeating: 0, count: length / 2)
            let status = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples += pcm.map { Float($0) / 32768 } }
        }

        let hop = Int(8000 / envelopeRate)
        let count = samples.count / hop
        guard count > 400 else { return nil } // < 2 detik

        var env = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i * hop, 1, &rms, vDSP_Length(hop)) }
            env[i] = log1p(rms * 100)
        }

        // High-pass: kurangi rata-rata bergerak 1 detik supaya korelasi tidak didominasi level DC.
        let window = Int(envelopeRate)
        var cumulative = [Float](repeating: 0, count: count + 1)
        for i in 0..<count { cumulative[i + 1] = cumulative[i] + env[i] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let lo = max(0, i - window / 2), hi = min(count, i + window / 2)
            out[i] = env[i] - (cumulative[hi] - cumulative[lo]) / Float(hi - lo)
        }
        return out
    }

    /// Detik di mana media `other` mulai relatif terhadap media `reference` (positif = other mulai lebih lambat).
    @concurrent
    static func offset(reference: [Float], other: [Float]) async -> Double? {
        // Kernel harus lebih pendek dari kedua sinyal supaya ada ruang untuk bergeser; 25% dari yang terpendek
        // (3–40 detik) cukup selama kedua rekaman tumpang tindih minimal selama itu.
        let shortest = min(reference.count, other.count)
        let window = min(max(Int(0.25 * Double(shortest)), Int(3 * envelopeRate)), Int(40 * envelopeRate), shortest - 1)
        guard window > 400 else { return nil }

        // Kasus 1: awal `other` muncul di dalam `reference`; kasus 2: awal `reference` muncul di dalam `other`.
        let forward = bestLag(signal: reference, kernel: Array(other[0..<window]))
        let backward = bestLag(signal: other, kernel: Array(reference[0..<window]))

        var best: (seconds: Double, score: Float)?
        if let f = forward { best = (Double(f.lag) / envelopeRate, f.score) }
        if let b = backward, b.score > (best?.score ?? -1) { best = (-Double(b.lag) / envelopeRate, b.score) }
        guard let best, best.score >= minScore else { return nil }
        return best.seconds
    }

    private static func bestLag(signal: [Float], kernel: [Float]) -> (lag: Int, score: Float)? {
        let n = signal.count, w = kernel.count
        guard n >= w, w > 0 else { return nil }
        let lags = n - w + 1

        var correlation = [Float](repeating: 0, count: lags)
        vDSP_conv(signal, 1, kernel, 1, &correlation, 1, vDSP_Length(lags), vDSP_Length(w))

        var cumulative = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cumulative[i + 1] = cumulative[i] + Double(signal[i] * signal[i]) }
        let kernelNorm = sqrt(kernel.reduce(0) { $0 + Double($1 * $1) })
        guard kernelNorm > 1e-6 else { return nil }

        var best: (lag: Int, score: Float) = (0, -1)
        for l in 0..<lags {
            let energy = cumulative[l + w] - cumulative[l]
            let score = Float(Double(correlation[l]) / (kernelNorm * sqrt(energy) + 1e-9))
            if score > best.score { best = (l, score) }
        }
        return best
    }
}
