import Foundation
import CoreGraphics

/// Properti klip yang bisa dianimasikan dengan keyframe.
nonisolated enum AnimProperty: String, CaseIterable, Sendable, Codable {
    case opacity, scale, rotation, positionX, positionY, cropLeft, cropRight, cropTop, cropBottom, volume

    var title: String {
        switch self {
        case .opacity: "Opacity"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .cropLeft: "Crop Left"
        case .cropRight: "Crop Right"
        case .cropTop: "Crop Top"
        case .cropBottom: "Crop Bottom"
        case .volume: "Volume"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .opacity: 0...1
        case .scale: 0.1...4
        case .rotation: -180...180
        case .positionX, .positionY: -1500...1500
        case .cropLeft, .cropRight, .cropTop, .cropBottom: 0...0.9
        case .volume: -60...12
        }
    }

    var defaultValue: Double {
        switch self {
        case .opacity, .scale: 1
        default: 0
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .opacity, .scale, .cropLeft, .cropRight, .cropTop, .cropBottom: "\(Int((v * 100).rounded()))%"
        case .rotation: String(format: "%.1f°", v)
        case .positionX, .positionY: "\(Int(v.rounded())) px"
        case .volume: String(format: "%+.1f dB", v)
        }
    }
}

/// Kurva interpolasi antar keyframe. `bezier` memakai dua titik kendali seperti cubic-bezier() di CSS.
nonisolated enum Easing: Sendable, Equatable, Codable {
    case linear
    case hold
    case bezier(Double, Double, Double, Double)

    static let easeIn = Easing.bezier(0.42, 0, 1, 1)
    static let easeOut = Easing.bezier(0, 0, 0.58, 1)
    static let easeInOut = Easing.bezier(0.42, 0, 0.58, 1)

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .hold: return "Hold"
        case .bezier:
            if self == .easeIn { return "Ease In" }
            if self == .easeOut { return "Ease Out" }
            if self == .easeInOut { return "Ease In-Out" }
            return "Custom"
        }
    }

    /// Titik kendali (x1, y1, x2, y2) untuk editor kurva.
    var controlPoints: (Double, Double, Double, Double) {
        switch self {
        case .linear, .hold: (0.33, 0.33, 0.66, 0.66)
        case .bezier(let a, let b, let c, let d): (a, b, c, d)
        }
    }

    /// u di 0...1 → progres yang sudah dilunakkan.
    func apply(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        switch self {
        case .linear: return u
        case .hold: return 0
        case .bezier(let x1, let y1, let x2, let y2):
            func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
                let inv = 1 - s
                return 3 * inv * inv * s * a + 3 * inv * s * s * b + s * s * s
            }
            // Cari s sehingga x(s) = u (x monoton selama x1, x2 ∈ 0...1), lalu kembalikan y(s).
            var lo = 0.0, hi = 1.0, s = u
            for _ in 0..<40 {
                let x = bezier(s, x1, x2)
                if abs(x - u) < 1e-7 { break }
                if x < u { lo = s } else { hi = s }
                s = (lo + hi) / 2
            }
            return bezier(s, y1, y2)
        }
    }
}

nonisolated struct Keyframe: Sendable, Codable {
    /// Waktu media (detik di dalam file sumber), jadi keyframe tetap menempel pada isi klip saat di-trim atau dibelah.
    var time: Double
    var value: Double
    /// Kurva dari keyframe ini menuju keyframe berikutnya.
    var easing: Easing = .easeInOut
}

nonisolated struct KeyframeTrack: Sendable, Codable {
    var keys: [Keyframe] = []

    var isEmpty: Bool { keys.isEmpty }
    static let tolerance = 0.02

    func index(near t: Double) -> Int? {
        keys.firstIndex { abs($0.time - t) < Self.tolerance }
    }

    func value(at t: Double) -> Double? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        guard let i = keys.lastIndex(where: { $0.time <= t }), i + 1 < keys.count else { return last.value }
        let a = keys[i], b = keys[i + 1]
        let u = (t - a.time) / (b.time - a.time)
        return a.value + (b.value - a.value) * a.easing.apply(u)
    }

    mutating func set(time: Double, value: Double) {
        if let i = index(near: time) {
            keys[i].value = value
        } else {
            keys.append(Keyframe(time: time, value: value))
            keys.sort { $0.time < $1.time }
        }
    }

    mutating func remove(near time: Double) {
        if let i = index(near: time) { keys.remove(at: i) }
    }
}

nonisolated enum BlendMode: String, CaseIterable, Sendable, Codable {
    case normal, multiply, screen, overlay, softLight, hardLight, add, darken, lighten, difference

    var title: String {
        switch self {
        case .normal: "Normal"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        default: rawValue.capitalized
        }
    }

    var filterName: String? {
        switch self {
        case .normal: nil
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .add: "CIAdditionCompositing"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .difference: "CIDifferenceBlendMode"
        }
    }
}

/// Semua yang dibutuhkan compositor untuk menggambar satu klip pada satu frame (aman dipakai lintas thread).
nonisolated struct RenderParams: Sendable {
    var base: CGAffineTransform        // orientasi + aspect-fit ke ukuran render (tanpa scale/posisi pengguna)
    var clipStart: Double              // posisi klip di timeline
    var mediaOffset: Double            // waktu media pada awal klip
    var values: [AnimProperty: Double]
    var tracks: [AnimProperty: KeyframeTrack]
    var blend: BlendMode
    var grades: [ColorGrade]                   // node grading aktif, dijalankan berurutan
    var keyer = Keyer()
    var removeBackground = false
    var mask = MaskSpec()
    var inputSpace = InputColorSpace.rec709
    var management = ColorManagementMode.off
    var titleImage: TitleImage?                // judul: gambar teks selebar frame (tanpa track media)
    var isAdjustmentLayer = false
    var fadeIn = 0.0                           // fade opacity (hanya dipakai judul)
    var fadeOut = 0.0
    var transition: TransitionSpec?
    var transitionDuration = 0.0               // overlap efektif dengan klip sebelumnya
    var clipDuration = 0.0

    func value(_ p: AnimProperty, atMedia t: Double) -> Double {
        tracks[p]?.value(at: t) ?? values[p] ?? p.defaultValue
    }
}

extension TimelineClip {
    func staticValue(_ p: AnimProperty) -> Double {
        switch p {
        case .opacity: opacity
        case .scale: scale
        case .rotation: rotation
        case .positionX: positionX
        case .positionY: positionY
        case .cropLeft: cropLeft
        case .cropRight: cropRight
        case .cropTop: cropTop
        case .cropBottom: cropBottom
        case .volume: volumeDB
        }
    }

    mutating func setStaticValue(_ p: AnimProperty, _ v: Double) {
        switch p {
        case .opacity: opacity = v
        case .scale: scale = v
        case .rotation: rotation = v
        case .positionX: positionX = v
        case .positionY: positionY = v
        case .cropLeft: cropLeft = v
        case .cropRight: cropRight = v
        case .cropTop: cropTop = v
        case .cropBottom: cropBottom = v
        case .volume: volumeDB = v
        }
    }

    /// Waktu media di posisi `timelineTime`.
    func mediaTime(at timelineTime: Double) -> Double { offsetInAsset + (timelineTime - startTime) }

    func value(_ p: AnimProperty, atMedia t: Double) -> Double {
        tracks[p]?.value(at: t) ?? staticValue(p)
    }

    func isAnimated(_ p: AnimProperty) -> Bool { !(tracks[p]?.isEmpty ?? true) }

    var renderValues: [AnimProperty: Double] {
        Dictionary(uniqueKeysWithValues: AnimProperty.allCases.map { ($0, staticValue($0)) })
    }
}
