import AppKit
import AVFoundation
import CoreImage
import Vision

// MARK: - Color grading (Core Image compositor)

nonisolated enum CubeLUTError: LocalizedError {
    case oneDimensional, invalid

    var errorDescription: String? {
        switch self {
        case .oneDimensional: return "LUT 1D belum didukung, gunakan LUT 3D (.cube dengan LUT_3D_SIZE)."
        case .invalid: return "File LUT tidak valid atau datanya tidak lengkap."
        }
    }
}

nonisolated struct CubeLUT: Sendable, Codable {
    let name: String
    let dimension: Int
    let data: Data // RGBA Float32, merah berubah paling cepat (sesuai CIColorCube)

    static func parse(_ text: String, name: String) throws -> CubeLUT {
        var size = 0
        var rgb: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first, !head.hasPrefix("#") else { continue }
            switch head {
            case "LUT_3D_SIZE": size = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            case "LUT_1D_SIZE": throw CubeLUTError.oneDimensional
            default:
                if parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                    rgb += [r, g, b]
                }
            }
        }
        guard size >= 2, size <= 128, rgb.count == size * size * size * 3 else { throw CubeLUTError.invalid }
        var rgba: [Float] = []
        rgba.reserveCapacity(rgb.count / 3 * 4)
        for i in stride(from: 0, to: rgb.count, by: 3) { rgba += [rgb[i], rgb[i + 1], rgb[i + 2], 1] }
        return CubeLUT(name: name, dimension: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

nonisolated struct ColorGrade: Sendable, Codable {
    var exposure = 0.0     // EV
    var contrast = 1.0
    var saturation = 1.0
    var lut: CubeLUT?
    var lift = ColorWheel()
    var gamma = ColorWheel()
    var gain = ColorWheel()
    var offset = ColorWheel()
    var temperature = 0.0  // −1 (dingin) ... 1 (hangat)
    var tint = 0.0         // −1 (hijau) ... 1 (magenta)
    var secondary = SecondaryGrade()

    var hasWheels: Bool { !(lift.isNeutral && gamma.isNeutral && gain.isNeutral && offset.isNeutral) || temperature != 0 || tint != 0 }
}

nonisolated final class GradeInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    struct Layer: Sendable {
        var trackID: CMPersistentTrackID?   // nil untuk judul
        var params: RenderParams
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true // nilai berubah antar frame (keyframe)
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Layer] // paling atas dulu

    init(timeRange: CMTimeRange, layers: [Layer]) {
        self.timeRange = timeRange
        self.layers = layers
        self.requiredSourceTrackIDs = layers.compactMap { $0.trackID.map { NSNumber(value: $0) } }
    }
}

nonisolated final class GradeCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "khcutpro.compositor", qos: .userInteractive)
    private let cancelLock = NSLock()
    nonisolated(unsafe) private var shouldCancel = false
    nonisolated(unsafe) private static let context = CIContext()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        nonisolated(unsafe) let request = request
        queue.async { [self] in
            // Setelah cancelAllPendingVideoCompositionRequests, request yang tertunda harus ditutup dengan finishCancelledRequest();
            // tanpa itu AVFoundation menunggu selamanya (export / playback macet).
            cancelLock.lock(); let cancelled = shouldCancel; cancelLock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? GradeInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "KHCutPro.Compositor", code: 1))
                return
            }
            let size = request.renderContext.size
            let rect = CGRect(origin: .zero, size: size)
            let time = request.compositionTime.seconds
            var canvas = CIImage(color: .black).cropped(to: rect)
            for layer in instruction.layers.reversed() {
                if layer.params.isAdjustmentLayer {
                    let original = canvas
                    var adjusted = ColorPipeline.apply(layer.params.grades, to: original)
                    let mediaTime = time - layer.params.clipStart
                    let opacity = min(max(layer.params.value(.opacity, atMedia: mediaTime), 0), 1)
                    if opacity < 1 {
                        adjusted = adjusted.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                        ])
                        canvas = adjusted.composited(over: original).cropped(to: rect)
                    } else {
                        canvas = adjusted.cropped(to: rect)
                    }
                    continue
                }
                let image: CIImage
                if let id = layer.trackID {
                    guard let buffer = request.sourceFrame(byTrackID: id) else { continue }
                    image = Self.render(layer, CIImage(cvPixelBuffer: buffer), CGFloat(CVPixelBufferGetHeight(buffer)), size, time)
                } else if let title = layer.params.titleImage {
                    image = Self.render(layer, title.image, size.height, size, time)
                } else { continue }
                if let name = layer.params.blend.filterName {
                    canvas = image.applyingFilter(name, parameters: ["inputBackgroundImage": canvas]).cropped(to: rect)
                } else {
                    canvas = image.composited(over: canvas)
                }
            }
            Self.context.render(canvas, to: output, bounds: rect, colorSpace: Self.colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelLock.lock(); shouldCancel = true; cancelLock.unlock()
        // Antrian serial: blok ini baru jalan setelah semua request tertunda dibatalkan, lalu pekerjaan baru normal lagi.
        queue.async { [self] in cancelLock.lock(); shouldCancel = false; cancelLock.unlock() }
    }

    private static func flip(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    private static func render(_ layer: GradeInstruction.Layer, _ source: CIImage, _ sourceHeight: CGFloat, _ size: CGSize, _ time: Double) -> CIImage {
        let p = layer.params
        let media = time - p.clipStart + p.mediaOffset
        func v(_ property: AnimProperty) -> Double { p.value(property, atMedia: media) }

        var image = source
        let w = source.extent.width, h = sourceHeight

        // Crop (fraksi dari tiap tepi). Core Image berorigin kiri-bawah, jadi "bottom" adalah y dari dasar.
        let l = v(.cropLeft), r = v(.cropRight), t = v(.cropTop), b = v(.cropBottom)
        if l + r + t + b > 0 {
            image = image.cropped(to: CGRect(x: l * w, y: b * h, width: max(1, w * (1 - l - r)), height: max(1, h * (1 - t - b))))
        }

        image = ColorPipeline.applyKeyer(p.keyer, to: image)
        image = ColorManagement.apply(p.inputSpace, p.management, to: image)
        image = ColorPipeline.apply(p.grades, to: image)
        image = ColorPipeline.applyMask(p.mask, to: image)

        // Transform dihitung di koordinat AVFoundation (origin kiri-atas); Core Image origin-nya kiri-bawah.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let user = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(-v(.rotation) * .pi / 180)))
            .concatenating(CGAffineTransform(scaleX: v(.scale), y: v(.scale)))
            .concatenating(CGAffineTransform(translationX: center.x + v(.positionX), y: center.y - v(.positionY)))
        image = image.transformed(by: flip(h).concatenating(p.base).concatenating(user).concatenating(flip(size.height)))
        if p.removeBackground {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            if let _ = try? VNImageRequestHandler(ciImage: image).perform([request]),
               let pixelBuffer = request.results?.first?.pixelBuffer {
                let maskImage = CIImage(cvPixelBuffer: pixelBuffer)
                let sx = image.extent.width / maskImage.extent.width
                let sy = image.extent.height / maskImage.extent.height
                let mask = maskImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    .cropped(to: image.extent)
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
                    kCIInputMaskImageKey: mask
                ]).cropped(to: image.extent)
            }
        }

        var opacity = v(.opacity)
        let local = time - p.clipStart
        if p.titleImage != nil { // fade judul memengaruhi opacity
            if p.fadeIn > 0 { opacity *= min(1, max(0, local / p.fadeIn)) }
            if p.fadeOut > 0 { opacity *= min(1, max(0, (p.clipDuration - local) / p.fadeOut)) }
        }

        var overBlack = false
        if let transition = p.transition, p.transitionDuration > 0.001, local < p.transitionDuration {
            let progress = min(1, max(0, local / p.transitionDuration))
            let full = CGRect(origin: .zero, size: size)
            switch transition.kind {
            case .dissolve:
                opacity *= progress
            case .dipToBlack:
                // Separuh pertama: layar menggelap menutupi klip sebelumnya; separuh kedua: klip ini muncul dari hitam.
                if progress < 0.5 {
                    return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: progress * 2)).cropped(to: full)
                }
                opacity *= (progress - 0.5) * 2
                overBlack = true
            case .wipeRight:
                image = image.cropped(to: CGRect(x: 0, y: 0, width: size.width * progress, height: size.height))
            case .wipeLeft:
                image = image.cropped(to: CGRect(x: size.width * (1 - progress), y: 0, width: size.width * progress, height: size.height))
            case .wipeDown: // Core Image berorigin kiri-bawah: bagian atas layar adalah y besar
                image = image.cropped(to: CGRect(x: 0, y: size.height * (1 - progress), width: size.width, height: size.height * progress))
            case .wipeUp:
                image = image.cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height * progress))
            }
        }

        if opacity < 1 {
            // Piksel sudah premultiplied, jadi RGB dan alpha harus diskalakan bersama.
            let o = CGFloat(max(0, opacity))
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: o)
            ])
        }
        if overBlack {
            image = image.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        }
        return image
    }
}

// MARK: - FCPXML export

enum FCPXMLExporter {
    private static var fps: Int { Int(projectFrameRate) }

    private static func time(_ seconds: Double) -> String {
        let frames = Int((seconds * projectFrameRate).rounded())
        return frames == 0 ? "0s" : "\(frames * 100)/\(fps * 100)s"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func xml(clips original: [TimelineClip], projectName: String) -> String {
        // Compound dan multicam diekspor sebagai klip biasa (hasil flatten), karena FCPXML tidak membawa struktur internal kita.
        let clips: [TimelineClip] = CompositionBuilder.flatten(original).map { flat in
            var c = flat.clip
            c.lane = flat.layer == 0 ? 0 : (flat.layer > 0 ? 1 : -1)
            if !flat.useAudio { c.isMuted = true }
            return c
        }
        var refs: [UUID: String] = [:]
        var assets: [MediaAsset] = []
        for c in clips where refs[c.asset.id] == nil {
            refs[c.asset.id] = "r\(refs.count + 2)"
            assets.append(c.asset)
        }

        let primary = clips.filter { $0.lane == 0 }.sorted { $0.startTime < $1.startTime }
        let connected = clips.filter { $0.lane != 0 }.sorted { $0.startTime < $1.startTime }
        let size = primary.first { $0.asset.naturalSize != .zero }?.asset.naturalSize ?? CGSize(width: 1920, height: 1080)
        let total = clips.map(\.endTime).max() ?? 0
        let primaryEnd = primary.map(\.endTime).max() ?? 0

        func adjustments(_ c: TimelineClip) -> String {
            var out = ""
            if c.asset.fileType == .video {
                if c.scale != 1 { out += "<adjust-transform scale=\"\(c.scale) \(c.scale)\"/>" }
                if c.opacity != 1 { out += "<adjust-blend amount=\"\(c.opacity)\"/>" }
            }
            if c.isMuted { out += "<adjust-volume amount=\"-96dB\"/>" }
            else if c.volumeDB != 0 { out += "<adjust-volume amount=\"\(c.volumeDB)dB\"/>" }
            return out
        }

        func element(_ c: TimelineClip, offset: Double, lane: Int?, nested: String = "") -> String {
            let laneAttr = lane.map { " lane=\"\($0)\"" } ?? ""
            return "<asset-clip ref=\"\(refs[c.asset.id]!)\"\(laneAttr) offset=\"\(time(offset))\" name=\"\(esc(c.asset.fileName))\" "
                + "start=\"\(time(c.offsetInAsset))\" duration=\"\(time(c.duration))\" tcFormat=\"NDF\">\(adjustments(c))\(nested)</asset-clip>"
        }

        var orphans = connected
        var spine = ""
        for p in primary {
            let children = connected.filter { $0.startTime >= p.startTime - 0.0005 && $0.startTime < p.endTime - 0.0005 }
            orphans.removeAll { o in children.contains { $0.id == o.id } }
            let nested = children.map { element($0, offset: p.offsetInAsset + ($0.startTime - p.startTime), lane: $0.lane) }.joined()
            spine += element(p, offset: p.startTime, lane: nil, nested: nested)
        }
        if !orphans.isEmpty {
            // Klip connected yang berada di luar primary storyline harus menempel pada gap.
            let nested = orphans.map { element($0, offset: $0.startTime - primaryEnd, lane: $0.lane) }.joined()
            spine += "<gap name=\"Gap\" offset=\"\(time(primaryEnd))\" start=\"0s\" duration=\"\(time(total - primaryEnd))\">\(nested)</gap>"
        }

        var resources = "<format id=\"r1\" frameDuration=\"100/\(fps * 100)s\" width=\"\(Int(size.width))\" height=\"\(Int(size.height))\"/>"
        for a in assets {
            let isVideo = a.fileType == .video || a.fileType == .image
            let duration = a.duration > 0 ? a.duration : clips.filter { $0.asset.id == a.id }.map { $0.offsetInAsset + $0.duration }.max() ?? 0
            resources += "<asset id=\"\(refs[a.id]!)\" name=\"\(esc(a.fileName))\" start=\"0s\" duration=\"\(time(duration))\" "
                + "hasVideo=\"\(isVideo ? 1 : 0)\" hasAudio=\"\(a.hasAudio ? 1 : 0)\"\(isVideo ? " format=\"r1\"" : "")>"
                + "<media-rep kind=\"original-media\" src=\"\(esc(a.url.absoluteString))\"/></asset>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10"><resources>\(resources)</resources>
        <library><event name="KHCutPro"><project name="\(esc(projectName))">
        <sequence format="r1" duration="\(time(total))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k"><spine>\(spine)</spine></sequence>
        </project></event></library></fcpxml>
        """
    }
}
