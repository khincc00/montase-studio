import AVFoundation
import Vision
import CoreImage

/// Frame hasil baca video untuk analisis.
nonisolated struct AnalysisFrame {
    var time: Double          // waktu media
    var buffer: CVPixelBuffer
}

nonisolated enum VideoReader {
    /// Membaca frame BGRA berukuran kecil dari rentang [start, start + duration), diambil sekitar `fps` frame per detik.
    @concurrent
    static func frames(url: URL, start: Double, duration: Double, fps: Double, maxWidth: Int = 480) async -> [AnalysisFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let info = try? await track.load(.naturalSize, .preferredTransform),
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let oriented = CGRect(origin: .zero, size: info.0).applying(info.1).size
        let width = min(maxWidth, Int(abs(oriented.width)))
        let height = Int(Double(width) * abs(oriented.height) / max(1, abs(oriented.width)))

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        let context = CIContext()
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var frames: [AnalysisFrame] = []
        var nextTime = start
        let step = 1 / max(1, fps)
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t + 0.0005 >= nextTime, let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            // Perkecil ke lebar analisis (orientasi sudah diterapkan lewat transform track).
            var small: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &small)
            guard let buffer = small else { continue }
            var image = CIImage(cvPixelBuffer: source).transformed(by: info.1)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let scale = CGFloat(width) / image.extent.width
            context.render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                           to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            frames.append(AnalysisFrame(time: t, buffer: buffer))
            nextTime = t + step * 0.95
        }
        return frames
    }
}

/// Hasil stabilisasi: koreksi translasi per waktu, dalam pecahan lebar/tinggi frame.
nonisolated struct StabilizationResult {
    var times: [Double]
    var dx: [Double]   // koreksi ke kanan sebagai pecahan lebar (positif = geser frame ke kanan)
    var dy: [Double]   // koreksi ke atas sebagai pecahan tinggi (positif = geser frame ke atas)
    var rawShake: Double   // simpangan baku gerak asli (pecahan lebar), untuk laporan
}

nonisolated enum Stabilizer {
    /// Menganalisis gerak kamera antar frame, lalu menghitung koreksi agar jalur kamera menjadi mulus.
    /// `smoothing` dalam detik: makin besar makin halus (gerak panning lambat tetap dipertahankan).
    @concurrent
    static func analyze(url: URL, start: Double, duration: Double, fps: Double = 30, smoothing: Double = 1.0) async -> StabilizationResult? {
        let frames = await VideoReader.frames(url: url, start: start, duration: duration, fps: fps)
        guard frames.count > 3 else { return nil }
        let handler = VNSequenceRequestHandler()
        let width = Double(CVPixelBufferGetWidth(frames[0].buffer)), height = Double(CVPixelBufferGetHeight(frames[0].buffer))

        // Gerak antar frame berurutan → jalur kumulatif.
        var path = [(x: Double, y: Double)](repeating: (0, 0), count: frames.count)
        for i in 1..<frames.count {
            let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: frames[i].buffer)
            var step = (x: 0.0, y: 0.0)
            if (try? handler.perform([request], on: frames[i - 1].buffer)) != nil,
               let result = request.results?.first as? VNImageTranslationAlignmentObservation {
                step = (Double(result.alignmentTransform.tx), Double(result.alignmentTransform.ty))
                // Gerak antar dua frame berurutan tidak mungkin sebesar >10% frame; itu salah cocok (pola berulang), abaikan.
                if abs(step.x) > width * 0.1 || abs(step.y) > height * 0.1 { step = (0, 0) }
            }
            path[i] = (path[i - 1].x + step.x, path[i - 1].y + step.y)
        }

        // Jalur mulus = rata-rata bergerak; koreksi = mulus − asli.
        let spacing = max(1e-3, (frames.last!.time - frames[0].time) / Double(frames.count - 1))
        let half = max(1, Int((smoothing / spacing) / 2))
        var dx = [Double](), dy = [Double]()
        for i in path.indices {
            let lo = max(0, i - half), hi = min(path.count - 1, i + half)
            let n = Double(hi - lo + 1)
            let mx = path[lo...hi].reduce(0) { $0 + $1.x } / n, my = path[lo...hi].reduce(0) { $0 + $1.y } / n
            dx.append((mx - path[i].x) / width)
            dy.append((my - path[i].y) / height)
        }
        // Dihitung terhadap jalur yang sudah dikurangi rata-rata bergerak, sehingga yang dilaporkan adalah getaran
        // (komponen frekuensi tinggi), bukan panning lambat.
        let shake = sqrt(dx.reduce(0) { $0 + $1 * $1 } / Double(dx.count))
        return StabilizationResult(times: frames.map(\.time), dx: dx, dy: dy, rawShake: shake)
    }
}

nonisolated struct TrackedPoint {
    var time: Double   // waktu media
    var x: Double      // 0...1 dari kiri
    var y: Double      // 0...1 dari atas
}

nonisolated enum PointTracker {
    /// Melacak objek di sekitar titik awal (koordinat 0...1 dari kiri-atas) sepanjang rentang klip.
    @concurrent
    static func track(url: URL, start: Double, duration: Double, from point: CGPoint, boxSize: Double = 0.12, fps: Double = 30) async -> [TrackedPoint] {
        let frames = await VideoReader.frames(url: url, start: start, duration: duration, fps: fps)
        guard let first = frames.first else { return [] }
        let handler = VNSequenceRequestHandler()
        // Vision berorigin kiri-bawah.
        let box = CGRect(x: point.x - boxSize / 2, y: (1 - point.y) - boxSize / 2, width: boxSize, height: boxSize)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        var observation = VNDetectedObjectObservation(boundingBox: box)
        var points = [TrackedPoint(time: first.time, x: point.x, y: point.y)]

        for frame in frames.dropFirst() {
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            guard (try? handler.perform([request], on: frame.buffer)) != nil,
                  let result = request.results?.first as? VNDetectedObjectObservation else { break }
            observation = result
            points.append(TrackedPoint(time: frame.time, x: Double(result.boundingBox.midX), y: 1 - Double(result.boundingBox.midY)))
            if result.confidence < 0.2 { break } // objek hilang
        }
        return points
    }
}
