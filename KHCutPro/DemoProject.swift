import Foundation

enum DemoProjectInstaller {
    static func installIfRequested(timeline: TimelineModel, library: MediaLibrary, transport: Transport) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--demo-project"),
              arguments.indices.contains(flag + 1) else { return }

        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            let footageNames = [
                "coast-dawn.mp4",
                "rice-terraces.mp4",
                "waterfall.mp4",
                "temple-dusk.mp4"
            ]
            let mediaURLs = try (footageNames + ["island-score.wav", "forest-ambience.wav"]).map { name -> URL in
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw DemoProjectError.missingMedia(name)
                }
                return url
            }

            var footage = zip(footageNames, mediaURLs.prefix(footageNames.count)).map { name, url in
                MediaAsset(url: url, fileName: name.replacingOccurrences(of: ".mp4", with: ""),
                           fileType: .video, duration: 5, originalApp: "KHCutPro Demo",
                           naturalSize: CGSize(width: 1280, height: 720))
            }
            for index in footage.indices {
                footage[index].frameRate = 24
                footage[index].codec = "H.264"
                footage[index].keywords = ["Bali", "B-roll", "Cinematic"]
                footage[index].rating = index == 0 ? 1 : 0
            }

            let audioURLs = Array(mediaURLs.suffix(2))
            let score = MediaAsset(url: audioURLs[0], fileName: "Island Score",
                                  fileType: .audio, duration: 20, originalApp: "KHCutPro Demo",
                                  hasAudio: true)
            let ambience = MediaAsset(url: audioURLs[1], fileName: "Forest Ambience",
                                      fileType: .audio, duration: 20, originalApp: "KHCutPro Demo",
                                      hasAudio: true)
            var assets = footage + [score, ambience]
            for index in assets.indices {
                assets[index].notes = index < footage.count
                    ? "Original illustrated travel footage · 24 fps · 1280×720"
                    : "Original demo soundtrack"
            }

            var clips: [TimelineClip] = []
            for index in footage.indices {
                var clip = TimelineClip(asset: footage[index], startTime: Double(index) * 5,
                                        duration: 5, lane: 0)
                clip.transition = index > 0 ? TransitionSpec(kind: .dissolve, duration: 0.45) : nil
                clip.nodes = [ColorNode(name: "Primary Grade")]
                clip.grade.temperature = 0.12
                clip.grade.contrast = 1.05
                clips.append(clip)
            }

            var title = TimelineClip(
                asset: .container(name: "ISLAND LIGHT", type: .title, duration: 0),
                startTime: 0.3, duration: 4.3, lane: 2
            )
            title.title = TitleSpec.make(.cinematic, text: "ISLAND LIGHT")
            title.title?.fontSize = 112
            title.title?.letterSpacing = 20
            clips.append(title)

            var lowerThird = TimelineClip(
                asset: .container(name: "BALI · INDONESIA", type: .title, duration: 0),
                startTime: 5.2, duration: 4.2, lane: 1
            )
            lowerThird.title = TitleSpec.make(.lowerThird, text: "BALI, INDONESIA\nA study in light")
            clips.append(lowerThird)

            for (index, start) in [2.4, 7.4, 12.4, 17.4].enumerated() {
                let asset = footage[(index + 1) % footage.count]
                var broll = TimelineClip(asset: asset, startTime: start, duration: 2.7, lane: 3)
                broll.scale = 0.36
                broll.positionX = 0.58
                broll.positionY = -0.34
                broll.opacity = 0.96
                clips.append(broll)
            }

            var adjustment = TimelineClip(
                asset: .container(name: "CINEMATIC GRADE", type: .adjustment, duration: 20),
                startTime: 0, duration: 20, lane: 4
            )
            adjustment.nodes = [ColorNode(name: "Film Finish")]
            adjustment.grade.saturation = 0.92
            adjustment.grade.contrast = 1.04
            clips.append(adjustment)

            var scoreClip = TimelineClip(asset: score, startTime: 0, duration: 20, lane: -2)
            scoreClip.role = .music
            scoreClip.volumeDB = -9
            scoreClip.fadeIn = 1.2
            scoreClip.fadeOut = 2
            clips.append(scoreClip)

            var ambienceClip = TimelineClip(asset: ambience, startTime: 0, duration: 20, lane: -3)
            ambienceClip.role = .effects
            ambienceClip.volumeDB = -18
            ambienceClip.fadeIn = 0.8
            ambienceClip.fadeOut = 1.5
            clips.append(ambienceClip)

            library.replaceAssets(assets, name: "ISLAND LIGHT — Bali Brand Film")
            let projectDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("KHCutPro", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true
            )
            let projectURL = projectDirectory.appendingPathComponent("Island Light.khcutpro")
            library.projectURL = projectURL
            library.selectAsset(footage[0].id)
            timeline.roleMix = [.music: RoleMix(volumeDB: -3), .effects: RoleMix(volumeDB: -2)]
            timeline.zoom = 40
            UserDefaults.standard.set(0.68, forKey: "khcutpro.timelineScale")
            timeline.replaceProject(clips: clips, snapshots: [], markIn: nil, markOut: nil)
            timeline.select(clips[0].id)
            timeline.seek(to: 2.8)
            transport.showSource(footage[0])

            let appearanceSettings: [(String, Any)] = [
                ("khcutpro.showBrowser", true),
                ("khcutpro.showViewer", true),
                ("khcutpro.showInspector", true),
                ("khcutpro.showTimeline", true),
                ("khcutpro.inspectorTab", InspectorView.Tab.color.rawValue)
            ]
            for (key, value) in appearanceSettings {
                UserDefaults.standard.set(value, forKey: key)
            }

            let data = try ProjectIO.encode(timeline: timeline, library: library)
            try data.write(to: projectURL, options: .atomic)
        } catch {
            library.alertMessage = "Tidak dapat memuat project demo: \(error.localizedDescription)"
        }
    }
}

private enum DemoProjectError: LocalizedError {
    case missingMedia(String)

    var errorDescription: String? {
        switch self {
        case .missingMedia(let name):
            "Media demo \(name) tidak ditemukan. Render media demo terlebih dahulu."
        }
    }
}
