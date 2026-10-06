import AVFoundation
import MediaToolbox
import AudioToolbox

/// Pengolahan audio per klip: high-pass, EQ 3 band, noise gate (reduksi derau), dan compressor.
nonisolated struct AudioFX: Sendable, Codable, Equatable {
    var enabled = false
    var highPassHz = 0.0            // 0 = mati
    var eqLowDB = 0.0               // low shelf 120 Hz
    var eqMidDB = 0.0               // peaking 1 kHz
    var eqHighDB = 0.0              // high shelf 6 kHz
    var compressor = false
    var thresholdDB = -18.0
    var ratio = 3.0
    var attackMs = 10.0
    var releaseMs = 120.0
    var makeupDB = 0.0
    var gate = false
    var gateThresholdDB = -45.0
    var gateReductionDB = -24.0

    var isActive: Bool {
        enabled && (highPassHz > 0 || eqLowDB != 0 || eqMidDB != 0 || eqHighDB != 0 || compressor || gate)
    }
}

nonisolated struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    // Koefisien RBJ Audio EQ Cookbook.
    private static func make(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(_ f: Double, q: Double = 0.7071, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), alpha = sin(w) / (2 * q)
        return make(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func peaking(_ f: Double, gainDB: Double, q: Double, rate: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w), alpha = sin(w) / (2 * q)
        return make(b0: 1 + alpha * A, b1: -2 * c, b2: 1 - alpha * A, a0: 1 + alpha / A, a1: -2 * c, a2: 1 - alpha / A)
    }

    static func lowShelf(_ f: Double, gainDB: Double, rate: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w), s = sin(w)
        let alpha = s / 2 * sqrt(2), k = 2 * sqrt(A) * alpha
        return make(b0: A * ((A + 1) - (A - 1) * c + k), b1: 2 * A * ((A - 1) - (A + 1) * c), b2: A * ((A + 1) - (A - 1) * c - k),
                    a0: (A + 1) + (A - 1) * c + k, a1: -2 * ((A - 1) + (A + 1) * c), a2: (A + 1) + (A - 1) * c - k)
    }

    static func highShelf(_ f: Double, gainDB: Double, rate: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w), s = sin(w)
        let alpha = s / 2 * sqrt(2), k = 2 * sqrt(A) * alpha
        return make(b0: A * ((A + 1) + (A - 1) * c + k), b1: -2 * A * ((A - 1) + (A + 1) * c), b2: A * ((A + 1) + (A - 1) * c - k),
                    a0: (A + 1) - (A - 1) * c + k, a1: 2 * ((A - 1) - (A + 1) * c), a2: (A + 1) - (A - 1) * c - k)
    }
}

/// Prosesor DSP yang dijalankan di dalam audio tap (bekerja langsung pada buffer Float32 dari AVFoundation).
nonisolated final class FXProcessor: @unchecked Sendable {
    let fx: AudioFX
    private var rate = 48000.0
    private var chains: [[Biquad]] = []
    private var detector = 0.0        // envelope compressor (linear)
    private var compGainDB = 0.0
    private var gateEnv = 0.0
    private var gateGainDB = 0.0

    init(_ fx: AudioFX) { self.fx = fx }

    func prepare(sampleRate: Double, channels: Int) {
        rate = sampleRate
        var chain: [Biquad] = []
        if fx.highPassHz > 0 { chain.append(.highPass(fx.highPassHz, rate: rate)) }
        if fx.eqLowDB != 0 { chain.append(.lowShelf(120, gainDB: fx.eqLowDB, rate: rate)) }
        if fx.eqMidDB != 0 { chain.append(.peaking(1000, gainDB: fx.eqMidDB, q: 0.9, rate: rate)) }
        if fx.eqHighDB != 0 { chain.append(.highShelf(6000, gainDB: fx.eqHighDB, rate: rate)) }
        chains = Array(repeating: chain, count: max(1, channels))
        detector = 0; compGainDB = 0; gateEnv = 0; gateGainDB = 0
    }

    private func coefficient(_ ms: Double) -> Double { exp(-1 / (rate * max(ms, 0.01) / 1000)) }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !buffers.isEmpty, frames > 0 else { return }
        // Non-interleaved: satu buffer per channel; interleaved: satu buffer dengan beberapa channel.
        let nonInterleaved = buffers.count > 1 || buffers[0].mNumberChannels == 1
        let channelCount = nonInterleaved ? buffers.count : Int(buffers[0].mNumberChannels)
        guard channelCount > 0, chains.count >= 1 else { return }
        if chains.count < channelCount { chains += Array(repeating: chains[0], count: channelCount - chains.count) }

        func pointer(_ c: Int) -> (UnsafeMutablePointer<Float>, Int)? {
            if nonInterleaved {
                guard let p = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                return (p, 1)
            }
            guard let p = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            return (p + c, channelCount)
        }
        let ptrs = (0..<channelCount).compactMap(pointer)
        guard ptrs.count == channelCount else { return }

        let attackC = coefficient(fx.attackMs), releaseC = coefficient(fx.releaseMs)
        let gateAttack = coefficient(5), gateRelease = coefficient(150), gateDetect = coefficient(30), gateRise = coefficient(1)
        let makeup = pow(10, fx.makeupDB / 20)

        for i in 0..<frames {
            var peak = 0.0
            var samples = [Double](repeating: 0, count: channelCount)
            for c in 0..<channelCount {
                let (p, stride) = ptrs[c]
                var x = Double(p[i * stride])
                for f in chains[c].indices { x = chains[c][f].process(x) }
                samples[c] = x
                peak = max(peak, abs(x))
            }

            var gainDB = 0.0
            if fx.gate {
                // Detektor energi lambat → expander: di bawah ambang, sinyal diredam sedalam gateReductionDB.
                gateEnv = peak > gateEnv ? peak + gateRise * (gateEnv - peak) : peak + gateDetect * (gateEnv - peak)
                let level = 20 * log10(max(gateEnv, 1e-9))
                let target = level < fx.gateThresholdDB ? fx.gateReductionDB : 0
                let c = target < gateGainDB ? gateAttack : gateRelease
                gateGainDB = target + c * (gateGainDB - target)
                gainDB += gateGainDB
            }
            if fx.compressor {
                detector = peak > detector ? peak + attackC * (detector - peak) : peak + releaseC * (detector - peak)
                let level = 20 * log10(max(detector, 1e-9))
                let over = level - fx.thresholdDB
                let target = over > 0 ? -over * (1 - 1 / max(fx.ratio, 1)) : 0
                let c = target < compGainDB ? attackC : releaseC
                compGainDB = target + c * (compGainDB - target)
                gainDB += compGainDB
            }
            let g = pow(10, gainDB / 20) * (fx.compressor ? makeup : 1)
            for c in 0..<channelCount {
                let (p, stride) = ptrs[c]
                p[i * stride] = Float(samples[c] * g)
            }
        }
    }
}

nonisolated enum FXTap {
    /// Membuat audio tap yang menjalankan `fx`; dipasang ke `AVMutableAudioMixInputParameters.audioTapProcessor`.
    static func make(_ fx: AudioFX) -> MTAudioProcessingTap? {
        let processor = Unmanaged.passRetained(FXProcessor(fx))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: processor.toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<FXProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let p = Unmanaged<FXProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                p.prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
            },
            unprepare: { _ in },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<FXProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frames: framesOut.pointee)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        if status != noErr { processor.release() }
        return status == noErr ? tap : nil
    }
}
