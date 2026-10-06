import Foundation
import CoreVideo
import CoreGraphics

nonisolated enum ScopeMode: String, CaseIterable, Sendable {
    case waveform = "Waveform", parade = "Parade", vectorscope = "Vectorscope", histogram = "Histogram"
}

/// Hitungan piksel mentah untuk semua scope dari satu frame (BGRA).
nonisolated struct ScopeData: Sendable {
    static let columns = 256
    static let paradeColumns = 128
    var waveform = [UInt32](repeating: 0, count: 256 * 256)               // [level * 256 + kolom]
    var parade = [[UInt32]](repeating: [UInt32](repeating: 0, count: 128 * 256), count: 3) // R, G, B
    var vectorscope = [UInt32](repeating: 0, count: 256 * 256)            // [(255 − Cr) * 256 + Cb]
    var histogram = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 4)    // R, G, B, luma
    var samples = 0
}

nonisolated enum Scopes {
    static func compute(_ buffer: CVPixelBuffer) -> ScopeData {
        var data = ScopeData()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return data }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let rowStep = max(1, height / 96)

        for column in 0..<ScopeData.columns {
            let x = min(width - 1, column * width / ScopeData.columns)
            var y = 0
            while y < height {
                let i = y * stride + x * 4
                let b = Double(pixels[i]), g = Double(pixels[i + 1]), r = Double(pixels[i + 2])
                let luma = min(255, Int(0.2126 * r + 0.7152 * g + 0.0722 * b))
                let cb = min(255, max(0, Int(128 + (-0.1146 * r - 0.3854 * g + 0.5 * b))))
                let cr = min(255, max(0, Int(128 + (0.5 * r - 0.4542 * g - 0.0458 * b))))
                let ri = Int(r), gi = Int(g), bi = Int(b)

                data.waveform[luma * 256 + column] += 1
                let pc = column / 2
                data.parade[0][ri * ScopeData.paradeColumns + pc] += 1
                data.parade[1][gi * ScopeData.paradeColumns + pc] += 1
                data.parade[2][bi * ScopeData.paradeColumns + pc] += 1
                data.vectorscope[(255 - cr) * 256 + cb] += 1
                data.histogram[0][ri] += 1
                data.histogram[1][gi] += 1
                data.histogram[2][bi] += 1
                data.histogram[3][luma] += 1
                data.samples += 1
                y += rowStep
            }
        }
        return data
    }

    /// Ubah hitungan jadi gambar RGBA; kecerahan memakai akar agar area jarang tetap terlihat.
    static func image(_ counts: [UInt32], width: Int, height: Int, tint: (Double, Double, Double)) -> CGImage? {
        guard let maxCount = counts.max(), maxCount > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let peak = Double(maxCount)
        for i in 0..<(width * height) {
            let c = counts[i]
            if c == 0 { continue }
            let v = min(1, 0.25 + 0.75 * (Double(c) / peak).squareRoot())
            bytes[i * 4] = UInt8(v * tint.0 * 255)
            bytes[i * 4 + 1] = UInt8(v * tint.1 * 255)
            bytes[i * 4 + 2] = UInt8(v * tint.2 * 255)
            bytes[i * 4 + 3] = 255
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
