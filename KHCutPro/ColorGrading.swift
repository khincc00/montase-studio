import Foundation
import CoreImage
import CoreGraphics

// MARK: - Model

/// Satu roda warna. `x`, `y` adalah posisi puck di dalam lingkaran (−1...1); `master` menggeser luminans.
nonisolated struct ColorWheel: Sendable, Equatable, Codable {
    var x = 0.0
    var y = 0.0
    var master = 0.0

    var radius: Double { min(1, hypot(x, y)) }

    /// Deviasi RGB dari posisi puck: sudut = hue (merah di kanan, berlawanan arah jarum jam), jarak = kekuatan.
    var tint: (r: Double, g: Double, b: Double) {
        let a = atan2(y, x), r = radius
        return (r * cos(a), r * cos(a - 2 * .pi / 3), r * cos(a + 2 * .pi / 3))
    }

    var isNeutral: Bool { x == 0 && y == 0 && master == 0 }
}

/// Seleksi warna berdasarkan hue / saturasi / luminans (nilai 0...1).
nonisolated struct Qualifier: Sendable, Equatable, Codable {
    var enabled = false
    var hueCenter = 0.0
    var hueWidth = 0.06
    var hueSoftness = 0.06
    var satMin = 0.15
    var satMax = 1.0
    var satSoftness = 0.1
    var lumMin = 0.0
    var lumMax = 1.0
    var lumSoftness = 0.1
    var invert = false
    var showMask = false

    /// 1 di dalam rentang, jatuh halus ke 0 di luar rentang sejauh `soft`.
    private static func band(_ v: Double, _ lo: Double, _ hi: Double, _ soft: Double) -> Double {
        let d = v < lo ? lo - v : (v > hi ? v - hi : 0)
        if d <= 0 { return 1 }
        let t = max(0, 1 - d / max(soft, 1e-4))
        return t * t * (3 - 2 * t)
    }

    func weight(h: Double, s: Double, v: Double) -> Double {
        var d = abs(h - hueCenter)
        d = min(d, 1 - d)
        let hw = Self.band(d, 0, hueWidth, hueSoftness)
        let w = hw * Self.band(s, satMin, satMax, satSoftness) * Self.band(v, lumMin, lumMax, lumSoftness)
        return invert ? 1 - w : w
    }
}

/// Jendela elips (power window); koordinat 0...1 dari kiri-atas.
nonisolated struct PowerWindow: Sendable, Equatable, Codable {
    var enabled = false
    var centerX = 0.5
    var centerY = 0.5
    var width = 0.5
    var height = 0.5
    var softness = 0.25
    var invert = false
}

/// Grading sekunder: penyesuaian yang hanya berlaku pada area terseleksi (qualifier dan/atau window).
nonisolated struct SecondaryGrade: Sendable, Equatable, Codable {
    var hueShift = 0.0      // −0.5...0.5 (putaran penuh = 1)
    var saturation = 1.0
    var brightness = 0.0    // −0.5...0.5
    var qualifier = Qualifier()
    var window = PowerWindow()

    var isActive: Bool { qualifier.enabled || window.enabled }
    var isIdentity: Bool { hueShift == 0 && saturation == 1 && brightness == 0 && !qualifier.showMask }
}

/// Chroma keyer: menghapus warna kunci (mis. green screen) berdasarkan hue dan saturasi.
nonisolated struct Keyer: Sendable, Codable, Equatable {
    var enabled = false
    var hue = 1.0 / 3.0         // 0...1; 0.333 = hijau, 0.667 = biru
    var tolerance = 0.1         // lebar hue yang dihapus penuh
    var softness = 0.08         // peralihan halus di tepi
    var minSaturation = 0.25    // piksel kurang jenuh (abu-abu, kulit pucat) tidak ikut dikey
    var spill = 0.7             // 0...1 kekuatan spill suppression pada piksel di sekitar warna kunci
    var choke = 0.0             // erosi matte (piksel)
    var feather = 0.0           // blur matte (piksel)
    var invert = false
    var showMatte = false

    /// Bobot 0...1: seberapa kuat piksel ini "bagian dari latar" (1 = hapus penuh).
    func weight(h: Double, s: Double, v: Double) -> Double {
        var d = abs(h - hue)
        d = min(d, 1 - d)
        let t = d <= tolerance ? 1 : max(0, 1 - (d - tolerance) / max(softness, 1e-4))
        let hueW = t * t * (3 - 2 * t)
        let satT = min(1, max(0, (s - minSaturation) / max(0.1, 1 - minSaturation) * 4))
        let valT = min(1, max(0, v * 6)) // area sangat gelap tidak dikey
        return hueW * satT * valT
    }
}

/// Mask bentuk pada klip: bagian di luar mask menjadi transparan.
nonisolated struct MaskSpec: Sendable, Codable, Equatable {
    enum Shape: String, Sendable, Codable, CaseIterable { case ellipse, rectangle }
    var enabled = false
    var shape = Shape.ellipse
    var centerX = 0.5
    var centerY = 0.5
    var width = 0.6
    var height = 0.6
    var feather = 0.1           // 0...1 (pecahan dari sisi terpendek)
    var invert = false
}

/// Satu node grading. Node dijalankan berurutan (serial); node yang dimatikan dilewati (bypass).
nonisolated struct ColorNode: Sendable, Codable, Identifiable {
    var id = UUID()
    var name = "Node"
    var enabled = true
    var grade = ColorGrade()
}

// MARK: - Cube builder

nonisolated enum ColorMath {
    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let hh = (h - floor(h)) * 6, i = Int(hh), f = hh - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// Cube RGBA Float32 (merah berubah paling cepat) dari fungsi warna.
    static func cube(size: Int, _ transform: (Double, Double, Double) -> (Double, Double, Double)) -> Data {
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        let m = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform(Double(r) / m, Double(g) / m, Double(b) / m)
                    values += [Float(min(max(out.0, 0), 1)), Float(min(max(out.1, 0), 1)), Float(min(max(out.2, 0), 1)), 1]
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

nonisolated final class CubeCache {
    struct Key: Hashable { var tag: Int; var values: [Double] }
    nonisolated(unsafe) private static var storage: [Key: Data] = [:]
    private static let lock = NSLock()

    static func data(_ key: Key, build: () -> Data) -> Data {
        lock.lock()
        if let hit = storage[key] { lock.unlock(); return hit }
        lock.unlock()
        let built = build()
        lock.lock()
        if storage.count > 48 { storage.removeAll() }
        storage[key] = built
        lock.unlock()
        return built
    }
}

// MARK: - Pipeline

/// Urutan efek warna per klip: LUT → roda warna → exposure/contrast/saturation → grading sekunder.
nonisolated enum ColorPipeline {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let cubeSize = 33

    private static func applyCube(_ data: Data, to image: CIImage, size: Int) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": data,
            "inputColorSpace": colorSpace
        ])
    }

    /// Jalankan semua node (sudah difilter yang aktif) secara berurutan.
    static func apply(_ grades: [ColorGrade], to input: CIImage) -> CIImage {
        grades.reduce(input) { apply($1, to: $0) }
    }

    /// Keyer → (node grading dijalankan oleh pemanggil) → mask.
    static func applyKeyer(_ k: Keyer, to input: CIImage) -> CIImage {
        guard k.enabled else { return input }
        let key = CubeCache.Key(tag: 3, values: [k.hue, k.tolerance, k.softness, k.minSaturation, k.spill, k.invert ? 1 : 0, k.showMatte ? 1 : 0])
        // Cube RGBA premultiplied: alpha = 1 − bobot latar; spill ditekan dengan menurunkan saturasi di sekitar hue kunci.
        let data = CubeCache.data(key) {
            var values = [Float]()
            let n = cubeSize
            values.reserveCapacity(n * n * n * 4)
            let m = Double(n - 1)
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let (rr, gg, bb) = (Double(r) / m, Double(g) / m, Double(b) / m)
                let (h, s, v) = ColorMath.hsv(rr, gg, bb)
                var alpha = 1 - k.weight(h: h, s: s, v: v)
                if k.invert { alpha = 1 - alpha }
                if k.showMatte {
                    values += [Float(alpha), Float(alpha), Float(alpha), 1]
                    continue
                }
                var d = abs(h - k.hue); d = min(d, 1 - d)
                let near = max(0, 1 - max(0, d - k.tolerance) / max(k.softness * 3, 0.05)) // zona spill lebih lebar dari matte
                let (sr, sg, sb) = ColorMath.rgb(h, s * (1 - k.spill * near * (s > k.minSaturation * 0.5 ? 1 : 0)), v)
                values += [Float(sr * alpha), Float(sg * alpha), Float(sb * alpha), Float(alpha)]
            } } }
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        var image = applyCube(data, to: input, size: cubeSize)

        if (k.choke > 0 || k.feather > 0) && !k.showMatte {
            // Matte dari alpha, dierosi / diblur, lalu dipakai memotong gambar.
            var matte = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]).cropped(to: input.extent)
            if k.choke > 0 { matte = matte.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: k.choke]).cropped(to: input.extent) }
            if k.feather > 0 { matte = matte.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: k.feather]).cropped(to: input.extent) }
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: input.extent)
            image = image.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": clear, "inputMaskImage": matte]).cropped(to: input.extent)
        }
        return image
    }

    static func applyMask(_ m: MaskSpec, to input: CIImage) -> CIImage {
        guard m.enabled else { return input }
        let extent = input.extent
        let side = min(extent.width, extent.height)
        var mask: CIImage
        switch m.shape {
        case .ellipse:
            var w = PowerWindow()
            w.enabled = true; w.centerX = m.centerX; w.centerY = m.centerY; w.width = m.width; w.height = m.height
            w.softness = m.feather; w.invert = false
            mask = windowMask(w, extent: extent)
        case .rectangle:
            let rect = CGRect(x: extent.minX + (m.centerX - m.width / 2) * extent.width,
                              y: extent.minY + (1 - m.centerY - m.height / 2) * extent.height,
                              width: m.width * extent.width, height: m.height * extent.height)
            mask = CIImage(color: .white).cropped(to: rect)
            let radius = m.feather * side / 2
            if radius > 0.5 { mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) }
            mask = mask.composited(over: CIImage(color: .black).cropped(to: extent)).cropped(to: extent)
        }
        if m.invert { mask = mask.applyingFilter("CIColorInvert") }
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        return input.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": clear, "inputMaskImage": mask]).cropped(to: extent)
    }

    static func apply(_ grade: ColorGrade, to input: CIImage) -> CIImage {
        var image = input
        if let lut = grade.lut { image = applyCube(lut.data, to: image, size: lut.dimension) }

        if grade.hasWheels {
            let key = CubeCache.Key(tag: 1, values: [
                grade.lift.x, grade.lift.y, grade.lift.master, grade.gamma.x, grade.gamma.y, grade.gamma.master,
                grade.gain.x, grade.gain.y, grade.gain.master, grade.offset.x, grade.offset.y, grade.offset.master,
                grade.temperature, grade.tint
            ])
            image = applyCube(CubeCache.data(key) { primaryCube(grade) }, to: image, size: cubeSize)
        }

        if grade.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": grade.exposure])
        }
        if grade.contrast != 1 || grade.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": grade.contrast,
                "inputSaturation": grade.saturation
            ])
        }

        if grade.secondary.isActive { image = applySecondary(grade.secondary, to: image) }
        return image
    }

    /// Lift / Gamma / Gain / Offset per kanal, ditambah temperature dan tint.
    static func primaryCube(_ g: ColorGrade) -> Data {
        let lt = g.lift.tint, gm = g.gamma.tint, gn = g.gain.tint, of = g.offset.tint
        let t = g.temperature, ti = g.tint
        let tempFactor = [1 + 0.25 * t, 1 - 0.2 * ti, 1 - 0.25 * t]

        func channel(_ v: Double, _ c: Int) -> Double {
            let l = [lt.r, lt.g, lt.b][c], gmm = [gm.r, gm.g, gm.b][c], gai = [gn.r, gn.g, gn.b][c], o = [of.r, of.g, of.b][c]
            let gain = max(0, 1 + g.gain.master + 0.5 * gai) * tempFactor[c]
            let lift = g.lift.master * 0.25 + 0.2 * l
            let offset = g.offset.master * 0.15 + 0.1 * o
            let gammaExp = pow(2, g.gamma.master + 0.6 * gmm)
            let x = min(max(v * gain + lift * (1 - v) + offset, 0), 1)
            return pow(x, 1 / gammaExp)
        }
        return ColorMath.cube(size: cubeSize) { r, g, b in (channel(r, 0), channel(g, 1), channel(b, 2)) }
    }

    static func applySecondary(_ s: SecondaryGrade, to base: CIImage) -> CIImage {
        let q = s.qualifier
        let key = CubeCache.Key(tag: 2, values: [
            s.hueShift, s.saturation, s.brightness, q.enabled ? 1 : 0, q.hueCenter, q.hueWidth, q.hueSoftness,
            q.satMin, q.satMax, q.satSoftness, q.lumMin, q.lumMax, q.lumSoftness, q.invert ? 1 : 0, q.showMask ? 1 : 0
        ])
        let data = CubeCache.data(key) {
            ColorMath.cube(size: cubeSize) { r, g, b in
                let (h, sat, v) = ColorMath.hsv(r, g, b)
                let w = q.enabled ? q.weight(h: h, s: sat, v: v) : 1
                if q.showMask && q.enabled { return (w, w, w) }
                let adjusted = ColorMath.rgb(h + s.hueShift, min(max(sat * s.saturation, 0), 1), min(max(v + s.brightness, 0), 1))
                return (r + (adjusted.0 - r) * w, g + (adjusted.1 - g) * w, b + (adjusted.2 - b) * w)
            }
        }
        var adjusted = applyCube(data, to: base, size: cubeSize)

        if s.window.enabled {
            let mask = windowMask(s.window, extent: base.extent)
            adjusted = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": base,
                "inputMaskImage": mask
            ]).cropped(to: base.extent)
        }
        return adjusted
    }

    /// Elips putih (di dalam) → hitam (di luar) dengan tepi lembut; di-invert bila diminta.
    static func windowMask(_ w: PowerWindow, extent: CGRect) -> CIImage {
        let cx = extent.minX + w.centerX * extent.width
        let cy = extent.minY + (1 - w.centerY) * extent.height // koordinat window dari atas, Core Image dari bawah
        let rx = max(1, w.width / 2 * extent.width), ry = max(1, w.height / 2 * extent.height)
        let inner = rx * max(0, 1 - w.softness)

        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: cx, y: cy),
            "inputRadius0": inner,
            "inputRadius1": rx,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black
        ])!.outputImage!
        // Lingkaran diregangkan secara vertikal di sekitar pusatnya menjadi elips.
        let stretch = CGAffineTransform(translationX: -cx, y: -cy)
            .scaledBy(x: 1, y: ry / rx)
            .translatedBy(x: cx, y: cy)
        var mask = gradient.transformed(by: stretch).cropped(to: extent)
        if w.invert { mask = mask.applyingFilter("CIColorInvert") }
        return mask
    }
}
