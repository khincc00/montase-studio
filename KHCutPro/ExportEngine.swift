import AVFoundation

enum ExportPreset: String, CaseIterable, Identifiable {
    case proRes422, proRes4444, h264Master, hevc, h2644K, h264HD, h264720, audioOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proRes422: "Apple ProRes 422"
        case .proRes4444: "Apple ProRes 4444"
        case .h264Master: "H.264 Master (kualitas tertinggi)"
        case .hevc: "HEVC (H.265)"
        case .h2644K: "H.264 4K UHD"
        case .h264HD: "H.264 1080p"
        case .h264720: "H.264 720p"
        case .audioOnly: "Audio saja (M4A)"
        }
    }

    var shortName: String {
        switch self {
        case .proRes422: "ProRes 422"
        case .proRes4444: "ProRes 4444"
        case .h264Master: "H264 Master"
        case .hevc: "HEVC"
        case .h2644K: "H264 4K"
        case .h264HD: "H264 1080p"
        case .h264720: "H264 720p"
        case .audioOnly: "Audio"
        }
    }

    var detail: String {
        switch self {
        case .proRes422: "Master untuk editing dan arsip; file besar"
        case .proRes4444: "Master dengan kualitas warna tertinggi dan alpha"
        case .h264Master: "Kualitas tertinggi, ukuran wajar"
        case .hevc: "File lebih kecil dari H.264 pada kualitas setara"
        case .h2644K: "3840×2160 UHD, bila didukung oleh codec dan sumber"
        case .h264HD: "Untuk web dan YouTube"
        case .h264720: "Untuk pratinjau dan berbagi cepat"
        case .audioOnly: "Hanya jalur audio"
        }
    }

    var avPreset: String {
        switch self {
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444: AVAssetExportPresetAppleProRes4444LPCM
        case .h264Master: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .h2644K: AVAssetExportPreset3840x2160
        case .h264HD: AVAssetExportPreset1920x1080
        case .h264720: AVAssetExportPreset1280x720
        case .audioOnly: AVAssetExportPresetAppleM4A
        }
    }

    var fileType: AVFileType {
        switch self {
        case .proRes422, .proRes4444, .hevc: .mov
        case .h264Master, .h2644K, .h264HD, .h264720: .mp4
        case .audioOnly: .m4a
        }
    }

    var fileExtension: String {
        switch self {
        case .proRes422, .proRes4444, .hevc: "mov"
        case .h264Master, .h2644K, .h264HD, .h264720: "mp4"
        case .audioOnly: "m4a"
        }
    }
}

enum ExportError: LocalizedError {
    case unavailable(ExportPreset)

    var errorDescription: String? {
        switch self {
        case .unavailable(let p): "Preset \(p.title) tidak tersedia untuk timeline ini."
        }
    }
}

enum ExportEngine {
    /// Ekspor komposisi dengan preset tertentu. `range` membatasi bagian timeline yang diekspor.
    static func run(clips: [TimelineClip], roleMix: [AudioRole: RoleMix] = [:], management: ColorManagementMode = .off, preset: ExportPreset, to url: URL, range: ClosedRange<Double>?,
                    progress: @escaping (Double) -> Void = { _ in }) async throws {
        let built = await CompositionBuilder.build(clips: clips, roleMix: roleMix, management: management)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset.avPreset) else {
            throw ExportError.unavailable(preset)
        }
        if preset != .audioOnly { session.videoComposition = built.videoComposition }
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        if let range {
            let total = built.composition.duration.seconds
            let end = min(range.upperBound, total)
            if end > range.lowerBound {
                session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                                end: CMTime(seconds: end, preferredTimescale: 600))
            }
        }
        try? FileManager.default.removeItem(at: url)

        nonisolated(unsafe) let watched = session
        let ticker = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { ticker.cancel() }
        try await session.export(to: url, as: preset.fileType)
        progress(1)
    }
}

extension ExportEngine {
    /// Pembantu singkat untuk uji: ekspor H.264 ke file bernama di direktori temporer.
    static func runToFile(clips: [TimelineClip], name: String, management: ColorManagementMode = .off) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        try await run(clips: clips, management: management, preset: .h264Master, to: url, range: nil)
        return url
    }
}
