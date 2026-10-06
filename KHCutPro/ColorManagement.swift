import Foundation
import CoreImage

/// Ruang warna sumber klip (input transform / IDT).
nonisolated enum InputColorSpace: String, CaseIterable, Sendable, Codable {
    case rec709, sLog3, logC3, rec2020, hlg

    var title: String {
        switch self {
        case .rec709: "Rec.709 (standar)"
        case .sLog3: "Sony S-Log3 / S-Gamut3.Cine"
        case .logC3: "ARRI LogC3 (EI 800) / AWG"
        case .rec2020: "Rec.2020 (SDR)"
        case .hlg: "HLG / Rec.2020"
        }
    }
}

/// Cara menampilkan hasil: standar (potong), filmic (tone mapping lembut), atau ACES (perkiraan kurva ACES).
nonisolated enum ColorManagementMode: String, CaseIterable, Sendable, Codable {
    case off, filmic, aces

    var title: String {
        switch self {
        case .off: "Mati (Rec.709 langsung)"
        case .filmic: "Managed — filmic"
        case .aces: "ACES (perkiraan RRT)"
        }
    }
}

nonisolated enum ColorManagement {
    typealias RGB = (r: Double, g: Double, b: Double)

    // MARK: Fungsi transfer (decode ke linear scene-referred)

    static func decodeSLog3(_ x: Double) -> Double {
        if x >= 171.2102946929 / 1023 { return pow(10, (x * 1023 - 420) / 261.5) * (0.18 + 0.01) - 0.01 }
        return (x * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
    }

    /// ARRI LogC3, EI 800.
    static func decodeLogC3(_ t: Double) -> Double {
        let cut = 0.010591, a = 5.555556, b = 0.052272, c = 0.247190, d = 0.385537, e = 5.367655, f = 0.092809
        if t > e * cut + f { return (pow(10, (t - d) / c) - b) / a }
        return (t - f) / e
    }

    /// BT.2100 HLG OETF terbalik → cahaya scene (0...1), lalu dipetakan kasar ke SDR.
    static func decodeHLG(_ x: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        let scene = x <= 0.5 ? x * x / 3 : (exp((x - c) / a) + b) / 12
        return scene * 3.0 // 12 → ~1.0 SDR white pada tampilan 1000 nit dipadatkan; skala kasar
    }

    static func srgbDecode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func srgbEncode(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    // MARK: Matriks gamut → Rec.709 linear

    private static let sGamut3CineToRec709: [[Double]] = [
        [1.6269474099, -0.5401385220, -0.0868088880],
        [-0.1785155272, 1.4179409274, -0.2394254002],
        [0.0044713680, -0.1955810390, 1.1911096710]]
    private static let awgToRec709: [[Double]] = [
        [1.617523, -0.537287, -0.080237],
        [-0.070573, 1.334613, -0.264040],
        [-0.021102, -0.226954, 1.248056]]
    private static let rec2020ToRec709: [[Double]] = [
        [1.6605, -0.5876, -0.0728],
        [-0.1246, 1.1329, -0.0083],
        [-0.0182, -0.1006, 1.1187]]
    private static let rec709ToAP1: [[Double]] = [
        [0.6131, 0.3395, 0.0474],
        [0.0702, 0.9164, 0.0134],
        [0.0206, 0.1096, 0.8698]]
    private static let ap1ToRec709: [[Double]] = [
        [1.7050, -0.6218, -0.0833],
        [-0.1302, 1.1408, -0.0106],
        [-0.0240, -0.1290, 1.1530]]

    private static func multiply(_ m: [[Double]], _ c: RGB) -> RGB {
        (m[0][0] * c.r + m[0][1] * c.g + m[0][2] * c.b,
         m[1][0] * c.r + m[1][1] * c.g + m[1][2] * c.b,
         m[2][0] * c.r + m[2][1] * c.g + m[2][2] * c.b)
    }

    /// Kurva filmic ACES (perkiraan Narkowicz) per kanal.
    private static func acesFit(_ x: Double) -> Double {
        let v = max(x, 0) * 0.6 // eksposur kompensasi agar abu-abu 18% mendekati posisi tampilan standar
        return min(max((v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14), 0), 1)
    }

    private static func filmic(_ x: Double) -> Double {
        // Hable/Uncharted2 yang dinormalisasi: shoulder lembut, toe ringan
        func f(_ v: Double) -> Double { ((v * (0.15 * v + 0.05) + 0.004) / (v * (0.15 * v + 0.5) + 0.06)) - 0.02 / 0.3 }
        return min(max(f(max(x, 0) * 2) / f(11.2), 0), 1)
    }

    /// Satu piksel: nilai terenkode sumber (0...1) → nilai tampilan Rec.709 (0...1).
    static func transform(_ input: RGB, space: InputColorSpace, mode: ColorManagementMode) -> RGB {
        var linear: RGB
        switch space {
        case .rec709:
            linear = (srgbDecode(input.r), srgbDecode(input.g), srgbDecode(input.b))
        case .sLog3:
            linear = multiply(sGamut3CineToRec709, (decodeSLog3(input.r), decodeSLog3(input.g), decodeSLog3(input.b)))
        case .logC3:
            linear = multiply(awgToRec709, (decodeLogC3(input.r), decodeLogC3(input.g), decodeLogC3(input.b)))
        case .rec2020:
            linear = multiply(rec2020ToRec709, (srgbDecode(input.r), srgbDecode(input.g), srgbDecode(input.b)))
        case .hlg:
            linear = multiply(rec2020ToRec709, (decodeHLG(input.r), decodeHLG(input.g), decodeHLG(input.b)))
        }
        switch mode {
        case .off:
            break
        case .filmic:
            linear = (filmic(linear.r), filmic(linear.g), filmic(linear.b)) // tone map linear; di-encode di bawah
        case .aces:
            let ap1 = multiply(rec709ToAP1, linear)
            let mapped = multiply(ap1ToRec709, (acesFit(ap1.r), acesFit(ap1.g), acesFit(ap1.b)))
            return (srgbEncode(mapped.r), srgbEncode(mapped.g), srgbEncode(mapped.b))
        }
        return (srgbEncode(linear.r), srgbEncode(linear.g), srgbEncode(linear.b))
    }

    static let cubeSize = 65

    /// Cube 65³ untuk satu kombinasi ruang warna dan mode (di-cache).
    static func cube(space: InputColorSpace, mode: ColorManagementMode) -> Data {
        let key = CubeCache.Key(tag: 10, values: [Double(InputColorSpace.allCases.firstIndex(of: space) ?? 0),
                                                  Double(ColorManagementMode.allCases.firstIndex(of: mode) ?? 0)])
        return CubeCache.data(key) {
            ColorMath.cube(size: cubeSize) { r, g, b in
                let o = transform((r, g, b), space: space, mode: mode)
                return (o.r, o.g, o.b)
            }
        }
    }

    static func apply(_ space: InputColorSpace, _ mode: ColorManagementMode, to image: CIImage) -> CIImage {
        guard space != .rec709 else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": cube(space: space, mode: mode),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!
        ])
    }
}
