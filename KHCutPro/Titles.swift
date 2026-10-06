import AppKit
import CoreImage
import Speech
import AVFoundation

// MARK: - Model

nonisolated enum TitlePreset: String, CaseIterable, Sendable {
    case basic, largeCenter, lowerThird, subtitle, subtitleBar, subtitlePop, cinematic, socialHook, newsBanner, endCard

    var title: String {
        switch self {
        case .basic: "Basic Title"
        case .largeCenter: "Large Center"
        case .lowerThird: "Lower Third"
        case .subtitle: "Subtitle"
        case .subtitleBar: "Subtitle Bar"
        case .subtitlePop: "Social Caption"
        case .cinematic: "Cinematic"
        case .socialHook: "Social Hook"
        case .newsBanner: "News Banner"
        case .endCard: "End Card"
        }
    }

    var icon: String {
        switch self {
        case .socialHook, .subtitlePop: "sparkles"
        case .newsBanner, .lowerThird: "rectangle.bottomthird.inset.filled"
        case .endCard, .cinematic: "play.rectangle"
        case .subtitle, .subtitleBar: "captions.bubble"
        default: "textformat"
        }
    }
}

nonisolated struct TitleSpec: Sendable, Codable, Equatable {
    var text = "Judul"
    var fontFamily = "Helvetica Neue"
    var fontSize = 96.0              // piksel pada tinggi 1080; diskalakan mengikuti ukuran render
    var bold = true
    var color: [Double] = [1, 1, 1, 1]
    var alignment = 1                // 0 kiri, 1 tengah, 2 kanan
    var positionX = 0.5              // pusat blok teks, pecahan dari kiri
    var positionY = 0.5              // pecahan dari atas
    var backgroundEnabled = false
    var backgroundColor: [Double] = [0, 0, 0, 0.6]
    var shadow = true
    var uppercase = false
    var letterSpacing = 0.0
    var isCaption = false
    var preset = TitlePreset.basic.rawValue

    static func make(_ preset: TitlePreset, text: String? = nil) -> TitleSpec {
        var s = TitleSpec()
        s.preset = preset.rawValue
        switch preset {
        case .basic:
            s.text = "Judul"
        case .largeCenter:
            s.text = "JUDUL BESAR"; s.fontSize = 180; s.uppercase = true; s.letterSpacing = 4
        case .lowerThird:
            s.text = "Nama Lengkap\nJabatan"; s.fontSize = 56; s.bold = false; s.alignment = 0
            s.positionX = 0.26; s.positionY = 0.82
            s.backgroundEnabled = true; s.backgroundColor = [0.05, 0.05, 0.08, 0.72]; s.shadow = false
        case .subtitle:
            s.text = "Teks subtitle"; s.fontSize = 54; s.bold = false
            s.positionY = 0.9; s.backgroundEnabled = true; s.backgroundColor = [0, 0, 0, 0.55]; s.shadow = false
            s.isCaption = true
        case .subtitleBar:
            s.text = "Subtitle dengan bar"; s.fontFamily = "Avenir Next"; s.fontSize = 48; s.bold = false
            s.positionY = 0.88; s.backgroundEnabled = true; s.backgroundColor = [0.03, 0.04, 0.06, 0.82]
            s.shadow = false; s.isCaption = true
        case .subtitlePop:
            s.text = "KATA PENTING"; s.fontFamily = "Avenir Next"; s.fontSize = 72; s.uppercase = true
            s.positionY = 0.82; s.backgroundEnabled = true; s.backgroundColor = [0.98, 0.32, 0.16, 0.94]
            s.shadow = true; s.isCaption = true
        case .cinematic:
            s.text = "CINEMATIC"; s.fontSize = 84; s.bold = false; s.uppercase = true; s.letterSpacing = 18
            s.color = [0.96, 0.93, 0.86, 1]
        case .socialHook:
            s.text = "TUNGGU DULU!"; s.fontFamily = "Avenir Next"; s.fontSize = 112
            s.uppercase = true; s.letterSpacing = 1
            s.positionY = 0.78
            s.backgroundEnabled = true; s.backgroundColor = [0.98, 0.32, 0.16, 0.95]; s.shadow = true
        case .newsBanner:
            s.text = "BERITA HARI INI\nRingkasan singkat"; s.fontFamily = "Avenir Next"
            s.fontSize = 54; s.alignment = 0; s.positionX = 0.28; s.positionY = 0.82
            s.backgroundEnabled = true; s.backgroundColor = [0.04, 0.12, 0.25, 0.9]; s.shadow = false
        case .endCard:
            s.text = "TERIMA KASIH\nSampai jumpa"; s.fontFamily = "Avenir Next"
            s.fontSize = 84; s.positionY = 0.72; s.backgroundEnabled = true
            s.backgroundColor = [0.03, 0.04, 0.07, 0.78]; s.shadow = false
        }
        if let text { s.text = text }
        return s
    }
}

nonisolated enum TransitionKind: String, CaseIterable, Sendable, Codable {
    case dissolve, dipToBlack, wipeRight, wipeLeft, wipeDown, wipeUp

    var title: String {
        switch self {
        case .dissolve: "Cross Dissolve"
        case .dipToBlack: "Dip to Black"
        case .wipeRight: "Wipe →"
        case .wipeLeft: "Wipe ←"
        case .wipeDown: "Wipe ↓"
        case .wipeUp: "Wipe ↑"
        }
    }
}

nonisolated struct TransitionSpec: Sendable, Codable, Equatable {
    var kind = TransitionKind.dissolve
    var duration = 1.0
}

/// Preset warna 1-klik (mengatur ColorGrade klip).
nonisolated enum LookPreset: String, CaseIterable, Sendable {
    case blackAndWhite, warmFilm, vintage, coolCinematic, vivid, faded, highContrast

    var title: String {
        switch self {
        case .blackAndWhite: "Hitam Putih"
        case .warmFilm: "Warm Film"
        case .vintage: "Vintage"
        case .coolCinematic: "Teal & Orange"
        case .vivid: "Vivid"
        case .faded: "Faded"
        case .highContrast: "High Contrast"
        }
    }

    func apply(to grade: inout ColorGrade) {
        var g = ColorGrade()
        g.lut = grade.lut // LUT pengguna tidak ditimpa
        switch self {
        case .blackAndWhite: g.saturation = 0; g.contrast = 1.12
        case .warmFilm: g.temperature = 0.35; g.contrast = 1.06; g.saturation = 0.95; g.lift.master = 0.03
        case .vintage: g.temperature = 0.22; g.tint = 0.08; g.contrast = 0.9; g.saturation = 0.72; g.lift.master = 0.08; g.gain.master = -0.04
        case .coolCinematic:
            g.lift.x = -0.8; g.lift.y = 0.2; g.gain.x = 0.7; g.gain.y = 0.15; g.contrast = 1.1; g.saturation = 1.08
        case .vivid: g.saturation = 1.4; g.contrast = 1.1
        case .faded: g.lift.master = 0.1; g.saturation = 0.8; g.contrast = 0.92
        case .highContrast: g.contrast = 1.35; g.saturation = 1.1
        }
        grade = g
    }
}

extension TimelineClip {
    var isTitle: Bool { title != nil }
}

// MARK: - Rendering

nonisolated struct TitleImage: @unchecked Sendable {
    let image: CIImage
}

@MainActor
enum TextRenderer {
    /// Menggambar teks (dan kotak latar bila aktif) ke gambar selebar frame dengan latar transparan.
    static func image(for spec: TitleSpec, size: CGSize) -> TitleImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let scale = size.height / 1080
        let px = max(8, spec.fontSize * scale)

        let manager = NSFontManager.shared
        let font = manager.font(withFamily: spec.fontFamily, traits: spec.bold ? .boldFontMask : [], weight: 5, size: px)
            ?? NSFont.systemFont(ofSize: px, weight: spec.bold ? .bold : .regular)

        let style = NSMutableParagraphStyle()
        style.alignment = [NSTextAlignment.left, .center, .right][min(max(spec.alignment, 0), 2)]
        let color = cgColor(spec.color)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
            .paragraphStyle: style
        ]
        if spec.letterSpacing != 0 { attributes[.kern] = spec.letterSpacing * scale }

        let text = spec.uppercase ? spec.text.uppercased() : spec.text
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = size.width * 0.88
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                              CGSize(width: maxWidth, height: size.height), nil)
        let textSize = CGSize(width: ceil(min(fit.width + 2, maxWidth)), height: ceil(fit.height))

        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Origin CGContext kiri-bawah; positionY dihitung dari atas.
        let center = CGPoint(x: spec.positionX * size.width, y: (1 - spec.positionY) * size.height)
        let rect = CGRect(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2,
                          width: textSize.width, height: textSize.height)

        if spec.backgroundEnabled {
            let pad = px * 0.4
            let box = rect.insetBy(dx: -pad * 1.4, dy: -pad * 0.7)
            context.setFillColor(cgColor(spec.backgroundColor))
            context.addPath(CGPath(roundedRect: box, cornerWidth: pad * 0.5, cornerHeight: pad * 0.5, transform: nil))
            context.fillPath()
        }
        if spec.shadow {
            context.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 8 * scale,
                              color: CGColor(gray: 0, alpha: 0.65))
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)

        guard let cg = context.makeImage() else { return nil }
        return TitleImage(image: CIImage(cgImage: cg))
    }

    private static func cgColor(_ c: [Double]) -> CGColor {
        let v = c + [1, 1, 1, 1]
        return CGColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: v[3])
    }
}

// MARK: - Captions (SRT)

nonisolated struct CaptionCue: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

nonisolated enum SRT {
    static func parse(_ text: String) -> [CaptionCue] {
        func seconds(_ s: Substring) -> Double? {
            let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        }
        var cues: [CaptionCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let range = lines[timing].components(separatedBy: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard range.count == 2, let a = seconds(Substring(range[0])), let b = seconds(Substring(range[1].split(separator: " ")[0])), b > a else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n")
            if !body.isEmpty { cues.append(CaptionCue(start: a, end: b, text: body)) }
        }
        return cues
    }

    static func write(_ cues: [CaptionCue]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n" }.joined(separator: "\n")
    }
}

// MARK: - Auto caption (Apple Speech)

enum TranscriptionError: LocalizedError {
    case notAuthorized, unavailable, empty, failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Izin pengenalan suara belum diberikan. Aktifkan di Pengaturan Sistem > Privasi & Keamanan > Pengenalan Suara."
        case .unavailable: "Pengenalan suara tidak tersedia untuk bahasa ini."
        case .empty: "Tidak ada ucapan yang terdeteksi pada klip ini."
        case .failed(let m): "Transkripsi gagal: \(m)"
        }
    }
}

struct TranscribedWord: Sendable {
    var text: String
    var start: Double   // waktu media
    var duration: Double
}

enum TranscriptionService {
    static func transcribe(url: URL, locale: Locale = .current) async throws -> [TranscribedWord] {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw TranscriptionError.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        let words: [TranscribedWord] = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        TranscribedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    })
                }
            }
        }
        guard !words.isEmpty else { throw TranscriptionError.empty }
        return words
    }

    /// Kelompokkan kata menjadi baris subtitle: maksimum 42 karakter atau 4 detik, atau jeda ucapan > 0,7 detik.
    static func cues(from words: [TranscribedWord]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [TranscribedWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(CaptionCue(start: first.start, end: last.start + last.duration, text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last {
                let chars = current.map(\.text).joined(separator: " ").count + w.text.count + 1
                if chars > 42 || w.start - (last.start + last.duration) > 0.7 || (w.start + w.duration) - current[0].start > 4 { flush() }
            }
            current.append(w)
        }
        flush()
        return cues
    }
}

// MARK: - Blank media (pengisi durasi untuk judul)

/// Klip hitam 1 detik yang dibuat sekali lalu dipakai berulang untuk memperpanjang komposisi
/// ketika judul melewati ujung media (track kosong tidak menambah durasi komposisi).
enum BlankMedia {
    static func url() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("khcutpro-blank-1s.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let pixels = buffer else { return nil }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
}
