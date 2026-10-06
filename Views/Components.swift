import SwiftUI
import AVKit
import UniformTypeIdentifiers

// MARK: - Palette (mengacu pada tema gelap Final Cut Pro)

enum FCP {
    static let background = Color(white: 0.085)
    static let panel = Color(white: 0.135)
    static let header = Color(white: 0.18)
    static let border = Color.white.opacity(0.08)
    static let secondary = Color(white: 0.64)
    static var selection: Color {
        EditorAccent(rawValue: UserDefaults.standard.string(forKey: "khcutpro.accent") ?? "")?.color
            ?? EditorAccent.amber.color
    }
    static let videoClip = Color(red: 0.22, green: 0.40, blue: 0.68)
    static let audioClip = Color(red: 0.18, green: 0.52, blue: 0.42)
    static let offlineClip = Color(red: 0.55, green: 0.18, blue: 0.18)
    static let multicamClip = Color(red: 0.16, green: 0.46, blue: 0.56)
    static let compoundClip = Color(red: 0.36, green: 0.34, blue: 0.62)
    static let titleClip = Color(red: 0.56, green: 0.32, blue: 0.62)
}

enum EditorAccent: String, CaseIterable, Identifiable {
    case amber
    case cyan
    case violet
    case mint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amber: "Amber"
        case .cyan: "Cyan"
        case .violet: "Violet"
        case .mint: "Mint"
        }
    }

    var color: Color {
        switch self {
        case .amber: Color(red: 1.0, green: 0.72, blue: 0.22)
        case .cyan: Color(red: 0.25, green: 0.78, blue: 0.95)
        case .violet: Color(red: 0.68, green: 0.52, blue: 1.0)
        case .mint: Color(red: 0.32, green: 0.83, blue: 0.62)
        }
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(FCP.header)
        .overlay(alignment: .bottom) { Rectangle().fill(FCP.border).frame(height: 1) }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @Environment(MediaLibrary.self) private var library
    @Environment(TimelineModel.self) private var timeline
    @State private var isFinderDropTargeted = false
    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Browser") {
                Text("\(library.filteredAssets.count)/\(library.assets.count) item")
                    .font(.system(size: 10))
                    .foregroundStyle(FCP.secondary)
                Button { library.isImporterPresented = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Import Media (⌘I)")
            }

            BrowserToolbar()
            if library.assets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("Tidak ada media")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Impor video, audio, atau FCPXML")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Button("Import Media…") { library.isImporterPresented = true }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(library.filteredAssets) { BrowserTile(asset: $0) }
                    }
                    .padding(10)
                }
            }
        }
        .background(FCP.panel)
        .overlay {
            if isFinderDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(FCP.selection, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(8)
                    .overlay {
                        Label("Lepaskan media untuk mengimpor", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isFinderDropTargeted, perform: importFinderDrop)
    }

    private func importFinderDrop(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    Task { @MainActor in library.alertMessage = "Gagal membaca file yang dijatuhkan: \(error.localizedDescription)" }
                    return
                }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let value = item as? Data {
                    url = URL(dataRepresentation: value, relativeTo: nil)
                } else if let value = item as? NSURL {
                    url = value as URL
                } else {
                    url = nil
                }
                guard let url else {
                    Task { @MainActor in library.alertMessage = "File yang dijatuhkan tidak dapat dibaca sebagai URL." }
                    return
                }
                Task { @MainActor in await library.importFiles([url], into: timeline) }
            }
        }
        return true
    }
}

struct BrowserTile: View {
    @Environment(MediaLibrary.self) private var library
    @Environment(TimelineModel.self) private var timeline
    @Environment(Transport.self) private var transport
    let asset: MediaAsset

    private var isSelected: Bool { library.selectedAssetIDs.contains(asset.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(Color.black)
                if let image = library.thumbnails[asset.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: asset.fileType.systemIcon)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if asset.proxyURL != nil {
                    Text("PROXY").font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.blue.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if asset.rating > 0 {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(FCP.selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(3)
                }
                if asset.isOffline {
                    Text("OFFLINE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(FCP.offlineClip)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if asset.duration > 0 {
                    Text(timecodeString(asset.duration))
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(.black.opacity(0.7))
                        .padding(3)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(isSelected ? FCP.selection : .clear, lineWidth: 2))

            Text(asset.fileName)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(isSelected ? FCP.selection : .white.opacity(0.85))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { transport.perform(.append, asset: asset) }
        .onTapGesture {
            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            library.selectAsset(asset.id, extend: extend)
            if !extend, asset.isEditable { transport.showSource(asset) }
        }
        .draggable(asset.id.uuidString)
        .contextMenu {
            Button("Append to Storyline") { transport.perform(.append, asset: asset) }
            Button("Insert at Playhead") { transport.perform(.insert, asset: asset) }
            Button("Connect to Primary Storyline") { transport.perform(.connect, asset: asset) }
            Divider()
            Button("New Multicam Clip from Selection…") { Task { await library.createMulticam(into: timeline) } }
                .disabled(library.selectedAssetIDs.count < 2)
            Button("Add as Audition Take to Selected Clip") {
                if let id = timeline.selectedClipID { timeline.addTake(to: id, asset: asset) }
                else { timeline.statusMessage = "Pilih klip di timeline terlebih dulu." }
            }
            if asset.fileType == .lut {
                Button("Apply LUT to Selected Clip") { timeline.applyLUT(at: asset.url) }
            }
            Divider()
            Button(asset.rating > 0 ? "Hapus dari Favorit" : "Tandai Favorit") { library.toggleFavorite(asset.id) }
            Button(asset.rating < 0 ? "Batalkan Penolakan" : "Tolak") { library.toggleRejected(asset.id) }
            if asset.fileType == .video {
                if asset.proxyURL == nil { Button("Buat Proxy") { Task { await library.generateProxy(for: asset, timeline: timeline) } } }
                else { Button("Hapus Proxy") { library.removeProxy(for: asset, timeline: timeline) } }
            }
            if asset.isOffline { Button("Relink…") { Task { await library.relinkManually(asset, timeline: timeline) } } }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
            Button("Remove from Library", role: .destructive) { library.remove(asset, from: timeline) }
        }
        .task { await library.loadThumbnail(for: asset) }
    }
}

// MARK: - Viewer

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct ViewerView: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(Transport.self) private var transport

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: transport.usesSource ? "Viewer — Source: \(transport.source.asset?.fileName ?? "")" : "Viewer — Timeline") {
                Text("\(Int(projectFrameRate))p")
                    .font(.system(size: 10))
                    .foregroundStyle(FCP.secondary)
            }
            HStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerSurface(player: transport.activePlayer)
                if !transport.usesSource { ViewerOverlay() }
                if !transport.usesSource, timeline.isTrackerPlacing { TrackerCrosshair() }
                if !transport.usesSource, timeline.clips.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "play.display")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("Timeline kosong")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            AudioMeter()
            }
            if !transport.usesSource, let multicam = timeline.selectedClip?.multicam {
                AngleBar(multicam: multicam)
            }
            TransportBar()
        }
        .background(FCP.panel)
    }
}

/// Pemilih angle multicam; mengganti angle di posisi playhead (juga saat playback).
struct AngleBar: View {
    @Environment(TimelineModel.self) private var timeline
    let multicam: MulticamData

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(multicam.angles.enumerated()), id: \.offset) { index, angle in
                    Button { timeline.switchAngle(index) } label: {
                        Text("\(index + 1)  \(angle.name)")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(index == multicam.activeVideo ? FCP.multicamClip : Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Ganti ke angle \(index + 1)")
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .background(FCP.header)
        .overlay(alignment: .top) { Rectangle().fill(FCP.border).frame(height: 1) }
    }
}

struct TimecodeText: View {
    @Environment(Transport.self) private var transport
    @Environment(TimelineModel.self) private var timeline
    var size: CGFloat = 12
    var timelineOnly = false

    var body: some View {
        Text(timecodeString(timelineOnly ? timeline.playhead : transport.time))
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .monospacedDigit()
    }
}

struct TransportBar: View {
    @Environment(Transport.self) private var transport
    @Environment(TimelineModel.self) private var timeline

    private var marksText: String {
        let marks = transport.usesSource
            ? (transport.source.currentMarks.markIn, transport.source.currentMarks.markOut)
            : (timeline.markIn, timeline.markOut)
        var parts: [String] = []
        if let i = marks.0 { parts.append("I \(timecodeString(i))") }
        if let o = marks.1 { parts.append("O \(timecodeString(o))") }
        parts.append(timecodeString(transport.duration))
        return parts.joined(separator: "  ")
    }

    private var rateText: String? {
        let r = transport.rate
        guard r != 0, r != 1 else { return nil }
        return r < 0 ? "◀◀ \(Int(abs(r)))×" : "▶▶ \(Int(r))×"
    }

    var body: some View {
        VStack(spacing: 0) {
            if transport.usesSource {
                Slider(value: Binding(get: { transport.source.position }, set: { transport.source.seek(to: $0) }),
                       in: 0...max(0.1, transport.source.duration))
                    .controlSize(.mini)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    TimecodeText(size: 11).foregroundStyle(.white.opacity(0.8))
                    if let rateText { Text(rateText).font(.system(size: 10, weight: .bold)).foregroundStyle(FCP.selection) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    button("backward.end.fill", help: "Go to Start") { transport.goToStart() }
                    button("backward.frame.fill", help: "Previous Frame (←)") { transport.step(frames: -1) }
                    button(transport.isPlaying ? "pause.fill" : "play.fill", help: "Play / Pause (Space)  •  J K L untuk shuttle", size: 16) { transport.togglePlay() }
                    button("forward.frame.fill", help: "Next Frame (→)") { transport.step(frames: 1) }
                    button("forward.end.fill", help: "Go to End") { transport.goToEnd() }
                }

                Text(marksText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FCP.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(FCP.header)
        .overlay(alignment: .top) { Rectangle().fill(FCP.border).frame(height: 1) }
    }

    private func button(_ icon: String, help: String, size: CGFloat = 12, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(help)
    }
}

// MARK: - Timeline

struct TimelinePanel: View {
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TimelineToolbar(viewportWidth: geo.size.width)
                TimelineCanvas()
            }
        }
        .background(FCP.background)
    }
}

struct TimelineToolbar: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(MediaLibrary.self) private var library
    @Environment(Transport.self) private var transport
    @State private var showEffects = false
    let viewportWidth: CGFloat

    var body: some View {
        @Bindable var timeline = timeline
        HStack(spacing: 6) {
            if let level = timeline.compoundStack.last {
                Button { timeline.closeCompound() } label: {
                    Label(level.name, systemImage: "chevron.left").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Kembali ke timeline induk")
            }

            ForEach(EditTool.allCases, id: \.self) { tool in
                Button { timeline.tool = tool } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 11))
                        .frame(width: 26, height: 20)
                        .background(timeline.tool == tool ? Color.white.opacity(0.22) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(tool.key)); select clips or drag.")
            }

            if timeline.tool == .trim {
                Picker("", selection: $timeline.trimMode) {
                    ForEach(TrimMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 210)
                .help(timeline.trimMode.help)
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            editButton("Connect", icon: "arrow.down.to.line.compact", key: "Q", operation: .connect)
            editButton("Insert", icon: "arrow.down.right.and.arrow.up.left", key: "W", operation: .insert)
            editButton("Append", icon: "arrow.right.to.line", key: "E", operation: .append)

            Button { showEffects.toggle() } label: {
                Label("Efek", systemImage: "sparkles.rectangle.stack").font(.system(size: 10)).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Judul, transisi, dan look 1-klik")
            .popover(isPresented: $showEffects) { EffectsGallery() }

            Spacer()
            TimecodeText(size: 14, timelineOnly: true).foregroundStyle(.white)
            if timeline.shuttleRate != 0, timeline.shuttleRate != 1 {
                Text(timeline.shuttleRate < 0 ? "◀◀ \(Int(abs(timeline.shuttleRate)))×" : "▶▶ \(Int(timeline.shuttleRate))×")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FCP.selection)
            }
            Spacer()

            Toggle("Snap", isOn: $timeline.snapping)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Snapping (N)")

            Button {
                let available = max(100, viewportWidth - 30)
                timeline.zoom = min(240, max(0.25, Double(available) / max(1, timeline.totalDuration + 15)))
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Fit entire timeline in view")

            Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(FCP.secondary)
            Slider(value: $timeline.zoom, in: 0.25...240)
                .frame(width: 100)
                .controlSize(.small)
            Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(FCP.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(FCP.header)
        .overlay(alignment: .bottom) { Rectangle().fill(FCP.border).frame(height: 1) }
    }

    private func editButton(_ title: String, icon: String, key: String, operation: EditOperation) -> some View {
        Button { transport.perform(operation) } label: {
            Label(title, systemImage: icon).font(.system(size: 10)).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(library.selectedAsset == nil)
        .help("\(title) klip yang dipilih di Browser, memakai tanda In/Out bila ada (\(key))")
    }
}

struct TimelineCanvas: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(MediaLibrary.self) private var library
    @AppStorage("khcutpro.timelineScale") private var timelineScale = 1.0

    private let rulerHeight: CGFloat = 26
    private let laneGap: CGFloat = 3

    private func laneHeight(_ lane: Int) -> CGFloat { (lane == 0 ? 58 : 38) * timelineScale }

    /// Lane dari atas ke bawah; selalu ada minimal satu lane connected dan satu lane audio.
    private var lanes: [Int] {
        let top = max(1, timeline.clips.map(\.lane).max() ?? 1)
        let bottom = min(-1, timeline.clips.map(\.lane).min() ?? -1)
        return Array((bottom...top).reversed())
    }

    private func laneY(_ lane: Int) -> CGFloat {
        var y = rulerHeight + 4
        for l in lanes {
            if l == lane { return y }
            y += laneHeight(l) + laneGap
        }
        return y
    }

    private func lane(atY y: CGFloat) -> Int {
        lanes.first { y >= laneY($0) && y < laneY($0) + laneHeight($0) + laneGap } ?? 0
    }

    var body: some View {
        let zoom = timeline.zoom
        let lanes = self.lanes
        let contentHeight = laneY(lanes.last ?? 0) + laneHeight(lanes.last ?? 0) + 30

        GeometryReader { geo in
            let width = max(geo.size.width, (timeline.totalDuration + 15) * zoom)
            let height = max(geo.size.height, contentHeight)

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(FCP.background)
                        .frame(width: width, height: height)
                        .onTapGesture { timeline.select(nil) }

                    ForEach(lanes, id: \.self) { l in
                        Rectangle()
                            .fill(Color.white.opacity(l == 0 ? 0.06 : 0.03))
                            .frame(width: width, height: laneHeight(l))
                            .offset(y: laneY(l))
                            .allowsHitTesting(false)
                        if let role = AudioRole.allCases.first(where: { $0.lane == l }) {
                            Text(role.laneLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(FCP.secondary.opacity(0.7))
                                .padding(.leading, 8)
                                .frame(width: width, height: laneHeight(l), alignment: .topLeading)
                                .offset(y: laneY(l) + 2)
                                .allowsHitTesting(false)
                        }
                    }

                    ForEach(timeline.clips) { clip in
                        TimelineClipView(clip: clip, height: laneHeight(clip.lane))
                            .offset(y: laneY(clip.lane))
                    }

                    TimelineRuler(width: width, height: rulerHeight)
                    SkimmerOverlay(height: height)
                    PlayheadOverlay(height: height)
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        if !timeline.isScrubbing { timeline.skim(to: p.x / timeline.zoom) }
                    case .ended: timeline.skim(to: nil)
                    }
                }
                .dropDestination(for: String.self) { items, location in
                    guard let asset = items.compactMap({ id in library.assets.first { $0.id.uuidString == id } }).first else { return false }
                    let time = max(0, location.x / timeline.zoom)
                    let target = lane(atY: location.y)
                    if target == 0 { timeline.insert(asset, at: time) } else { timeline.connect(asset, at: time, lane: target) }
                    return true
                }
            }
        }
    }
}

struct TimelineRuler: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(Transport.self) private var transport
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let zoom = timeline.zoom
        let markIn = timeline.markIn, markOut = timeline.markOut, total = timeline.totalDuration
        let markers = timeline.markers
        Canvas { context, size in
            if markIn != nil || markOut != nil {
                let x0 = (markIn ?? 0) * zoom
                let x1 = (markOut ?? max(total, (markIn ?? 0) + 1)) * zoom
                context.fill(Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)), with: .color(FCP.selection.opacity(0.28)))
            }
            for marker in markers {
                let x = marker.time * zoom
                var flag = Path()
                flag.move(to: CGPoint(x: x, y: size.height)); flag.addLine(to: CGPoint(x: x, y: size.height - (marker.isBeat ? 8 : 14)))
                context.stroke(flag, with: .color(marker.isBeat ? .cyan.opacity(0.7) : .orange), lineWidth: 1.5)
                if !marker.isBeat {
                    var tag = Path()
                    tag.move(to: CGPoint(x: x, y: 2)); tag.addLine(to: CGPoint(x: x + 7, y: 6)); tag.addLine(to: CGPoint(x: x, y: 10)); tag.closeSubpath()
                    context.fill(tag, with: .color(.orange))
                    context.draw(Text(marker.name).font(.system(size: 8)).foregroundColor(.orange), at: CGPoint(x: x + 10, y: 6), anchor: .leading)
                }
            }
            let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let major = steps.first { $0 * zoom >= 110 } ?? 600
            let minor = major / 5
            var t = 0.0
            var index = 0
            while t * zoom < size.width {
                let x = t * zoom
                let isMajor = index % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 9 : 4)))
                context.stroke(path, with: .color(.white.opacity(isMajor ? 0.5 : 0.25)), lineWidth: 1)
                if isMajor {
                    context.draw(Text(timecodeString(t)).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.55)),
                                 at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                }
                t += minor
                index += 1
            }
        }
        .frame(width: width, height: height)
        .background(FCP.header)
        .overlay(alignment: .bottom) { Rectangle().fill(FCP.border).frame(height: 1) }
        .contentShape(Rectangle())
        .help("Scrub playhead: drag left/right to move through the timeline.")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    timeline.isScrubbing = true
                    transport.showTimeline()
                    timeline.pause()
                    timeline.seek(to: value.location.x / timeline.zoom)
                }
                .onEnded { _ in timeline.isScrubbing = false }
        )
    }
}

struct PlayheadOverlay: View {
    @Environment(TimelineModel.self) private var timeline
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.white).frame(width: 1.5, height: height)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .offset(y: -1)
        }
        .frame(width: 12, height: height, alignment: .top)
        .offset(x: timeline.playhead * timeline.zoom - 6)
        .allowsHitTesting(false)
    }
}

struct SkimmerOverlay: View {
    @Environment(TimelineModel.self) private var timeline
    let height: CGFloat

    var body: some View {
        if let t = timeline.skimTime, !timeline.isPlaying {
            Rectangle()
                .fill(.white.opacity(0.45))
                .frame(width: 1, height: height)
                .offset(x: t * timeline.zoom)
                .allowsHitTesting(false)
        }
    }
}

struct TimelineClipView: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(MediaLibrary.self) private var library
    @Environment(Transport.self) private var transport
    @AppStorage("khcutpro.showInspector") private var showInspector = true
    let clip: TimelineClip
    let height: CGFloat
    @AppStorage("khcutpro.timelineScale") private var timelineScale = 1.0

    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var headTrim: CGFloat = 0
    @State private var tailTrim: CGFloat = 0
    @State private var slipText: String?
    @State private var fadeDragging = false

    private var laneStep: CGFloat { 38 * timelineScale + 3 }

    private var isSelected: Bool { timeline.selectedClipIDs.contains(clip.id) }
    private var isAudio: Bool { clip.asset.fileType == .audio }
    private var baseColor: Color {
        if clip.asset.isOffline { return FCP.offlineClip }
        if clip.isAdjustmentLayer { return Color(red: 0.72, green: 0.46, blue: 0.17) }
        if clip.multicam != nil { return FCP.multicamClip }
        if clip.isCompound { return FCP.compoundClip }
        if clip.title?.isCaption == true { return Color(red: 0.35, green: 0.42, blue: 0.78) }
        if clip.isTitle { return FCP.titleClip }
        return isAudio ? FCP.audioClip : FCP.videoClip
    }

    var body: some View {
        let zoom = timeline.zoom
        let width = max(6, clip.duration * zoom - headTrim + tailTrim)

        ZStack(alignment: .topLeading) {
            Rectangle().fill(baseColor.opacity(0.55))

            if !isAudio, !clip.isAdjustmentLayer, let id = clip.thumbnailAssetID,
               let frames = library.filmstrips[id], !frames.isEmpty {
                let tile = height * 16 / 9
                HStack(spacing: 0) {
                    ForEach(0..<min(80, Int(width / tile) + 1), id: \.self) { index in
                        Image(nsImage: frames[index % frames.count])
                            .resizable()
                            .scaledToFill()
                            .frame(width: tile, height: height)
                            .clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipped()
                .opacity(0.85)
            } else if !isAudio, !clip.isAdjustmentLayer, let id = clip.thumbnailAssetID,
                      let image = library.thumbnails[id] {
                let tile = height * 16 / 9
                HStack(spacing: 0) {
                    ForEach(0..<min(60, Int(width / tile) + 1), id: \.self) { _ in
                        Image(nsImage: image).resizable().scaledToFill().frame(width: tile, height: height).clipped()
                    }
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipped()
                .opacity(0.85)
            }

            if !clip.isContainer, !clip.isTitle, isAudio || clip.asset.hasAudio {
                WaveformView(assetID: clip.asset.id, offset: clip.offsetInAsset - Double(headTrim) / zoom, duration: Double(width) / zoom, zoom: zoom,
                             color: Color.white.opacity(isAudio ? 0.75 : 0.5))
                    .frame(height: isAudio ? height - 14 : 18)
                    .frame(maxHeight: .infinity, alignment: isAudio ? .bottom : .bottom)
                    .padding(.top, isAudio ? 14 : 0)
                    .task { await WaveformCache.shared.ensure(clip.asset) }
            }

            HStack(spacing: 4) {
                if clip.isContainer || clip.isTitle || clip.isAdjustmentLayer {
                    Image(systemName: clip.title?.isCaption == true ? "captions.bubble" : clip.asset.fileType.systemIcon)
                        .font(.system(size: 8))
                }
                Text(clip.asset.isOffline ? "\(clip.displayName) — Media Offline" : clip.displayName)
                    .lineLimit(1)
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .frame(width: width, height: 14, alignment: .leading)
            .background(baseColor)
            .foregroundStyle(.white)

            if clip.isAudition, width > 90 { auditionBadge }
            if isSelected, !clip.isContainer, isAudio || clip.asset.hasAudio, width > 40 {
                fadeShapes(width: width, zoom: zoom)
                fadeHandle(isIn: true, width: width, zoom: zoom)
                fadeHandle(isIn: false, width: width, zoom: zoom)
            }
            if let slipText {
                Text(slipText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(4)
                    .background(.black.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle()
                .stroke(isSelected ? FCP.selection : Color.black.opacity(0.5), lineWidth: isSelected ? 2 : 1)

            HStack(spacing: 0) {
                trimHandle(.head)
                Spacer(minLength: 0)
                trimHandle(.tail)
            }
        }
        .coordinateSpace(name: "clip")
        .frame(width: width, height: height)
        .clipped()
        .offset(x: clip.startTime * zoom + dragX + headTrim, y: dragY)
        .zIndex(dragX != 0 || dragY != 0 ? 10 : (isSelected ? 1 : 0))
        .simultaneousGesture(bodyDrag)
        .simultaneousGesture(
            SpatialTapGesture().onEnded { tap in
                switch timeline.tool {
                case .select, .trim:
                    let flags = NSEvent.modifierFlags
                    timeline.select(clip.id, extend: flags.contains(.command) || flags.contains(.shift))
                    transport.showTimeline()
                case .blade:
                    timeline.split(clip.id, at: clip.startTime + tap.location.x / timeline.zoom)
                }
            }
        )
        .onContinuousHover { phase in
            guard !timeline.isPlaying else { return }
            switch phase {
            case .active(let point):
                timeline.skim(to: clip.startTime + min(max(point.x / timeline.zoom, 0), clip.duration))
            case .ended:
                timeline.skim(to: nil)
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { _ in
                if clip.isCompound {
                    timeline.select(clip.id)
                    timeline.openCompound()
                }
            }
        )
        .contextMenu {
            Button("Blade at Playhead") { timeline.select(clip.id); timeline.splitAtPlayhead() }
            if clip.isTitle {
                Button(clip.title?.isCaption == true ? "Edit Caption Text…" : "Edit Title Text…",
                       systemImage: "text.cursor") {
                    timeline.select(clip.id)
                    showInspector = true
                }
            }
            Divider()
            if clip.lane == 0, !clip.isTitle {
                Menu("Transition") {
                    ForEach(TransitionKind.allCases, id: \.self) { kind in
                        Button(kind.title) { timeline.setTransition(clip.id, TransitionSpec(kind: kind, duration: 1)) }
                    }
                    if clip.transition != nil {
                        Divider()
                        Button("Remove Transition") { timeline.setTransition(clip.id, nil) }
                    }
                }
            }
            Button("New Compound Clip") { if !isSelected { timeline.select(clip.id) }; timeline.makeCompound() }
            if clip.isCompound {
                Button("Open Compound Clip") { timeline.select(clip.id); timeline.openCompound() }
                Button("Break Apart Compound Clip") { timeline.select(clip.id); timeline.breakApartSelected() }
            }
            if !clip.isContainer {
                Button("Add Browser Selection as Audition Take") {
                    if let asset = library.selectedAsset { timeline.addTake(to: clip.id, asset: asset) }
                    else { timeline.statusMessage = "Pilih media di Browser terlebih dulu." }
                }
            }
            if clip.isAudition {
                Button("Next Take") { timeline.cycleTake(clip.id, by: 1) }
                Button("Previous Take") { timeline.cycleTake(clip.id, by: -1) }
                Button("Finalize Audition") { timeline.finalizeAudition(clip.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { timeline.select(clip.id); timeline.deleteSelected() }
        }
        .task {
            guard let id = clip.thumbnailAssetID,
                  let asset = library.assets.first(where: { $0.id == id }) else { return }
            await library.loadThumbnail(for: asset)
        }
    }

    /// Segitiga gelap menunjukkan bagian yang diredam oleh fade.
    private func fadeShapes(width: CGFloat, zoom: Double) -> some View {
        let fin = CGFloat(clip.fadeIn * zoom), fout = CGFloat(clip.fadeOut * zoom)
        return Path { path in
            if fin > 1 {
                path.move(to: CGPoint(x: 0, y: 14)); path.addLine(to: CGPoint(x: fin, y: 14))
                path.addLine(to: CGPoint(x: 0, y: height)); path.closeSubpath()
            }
            if fout > 1 {
                path.move(to: CGPoint(x: width, y: 14)); path.addLine(to: CGPoint(x: width - fout, y: 14))
                path.addLine(to: CGPoint(x: width, y: height)); path.closeSubpath()
            }
        }
        .fill(Color.black.opacity(0.45))
        .allowsHitTesting(false)
    }

    private func fadeHandle(isIn: Bool, width: CGFloat, zoom: Double) -> some View {
        let x = isIn ? CGFloat(clip.fadeIn * zoom) : width - CGFloat(clip.fadeOut * zoom)
        return Rectangle()
            .fill(Color.white)
            .frame(width: 8, height: 8)
            .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .position(x: min(max(x, 4), width - 4), y: 19)
            .help(isIn ? "Seret untuk fade in" : "Seret untuk fade out")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("clip"))
                    .onChanged { value in
                        if !fadeDragging { timeline.checkpoint(); fadeDragging = true }
                        let seconds = isIn ? value.location.x / zoom : (width - value.location.x) / zoom
                        let limit = clip.duration * 0.9
                        timeline.updateClip(clip.id) {
                            if isIn { $0.fadeIn = min(max(0, seconds), limit) } else { $0.fadeOut = min(max(0, seconds), limit) }
                        }
                    }
                    .onEnded { _ in fadeDragging = false }
            )
    }

    private var auditionBadge: some View {
        HStack(spacing: 3) {
            Button { timeline.cycleTake(clip.id, by: -1) } label: { Image(systemName: "chevron.left") }
            Text("\(clip.activeTake + 1)/\(clip.takes.count)")
            Button { timeline.cycleTake(clip.id, by: 1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.black.opacity(0.7), in: Capsule())
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    // MARK: Gestures

    /// Select: pindah. Trim + Slip: geser isi. Trim + Slide: geser klip di antara tetangganya.
    private var bodyDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let zoom = timeline.zoom
                switch timeline.tool {
                case .select:
                    if !isSelected { timeline.select(clip.id) }
                    dragX = value.translation.width
                    dragY = clip.lane == 0 ? 0 : value.translation.height
                case .trim where timeline.trimMode == .slide:
                    guard let range = timeline.slideRange(clip) else { return }
                    let delta = min(max(value.translation.width / zoom, range.lowerBound), range.upperBound)
                    dragX = delta * zoom
                case .trim where timeline.trimMode == .slip:
                    let range = timeline.slipRange(clip)
                    let delta = min(max(-value.translation.width / zoom, range.lowerBound), range.upperBound)
                    slipText = String(format: "Slip %+.2fs", delta)
                default:
                    break
                }
            }
            .onEnded { value in
                defer { dragX = 0; dragY = 0; slipText = nil }
                switch timeline.tool {
                case .select:
                    var start = clip.startTime + value.translation.width / timeline.zoom
                    var shift = 0
                    if clip.lane != 0 {
                        start = timeline.snappedStart(start, duration: clip.duration, excluding: clip.id)
                        shift = -Int((value.translation.height / laneStep).rounded())
                    }
                    timeline.moveClip(clip.id, toStart: start, laneShift: shift)
                case .trim where timeline.trimMode == .slide:
                    timeline.slide(clip.id, delta: value.translation.width / timeline.zoom)
                case .trim where timeline.trimMode == .slip:
                    timeline.slip(clip.id, delta: -value.translation.width / timeline.zoom)
                default:
                    break
                }
            }
    }

    private var handlesEnabled: Bool {
        timeline.tool == .select || (timeline.tool == .trim && (timeline.trimMode == .ripple || timeline.trimMode == .roll))
    }

    /// Roll hanya berlaku bila ada klip yang bersebelahan persis di sisi itu; selain itu jatuh ke ripple.
    private func rollNeighbor(_ edge: ClipEdge) -> TimelineClip? {
        guard timeline.tool == .trim, timeline.trimMode == .roll else { return nil }
        return timeline.neighbor(of: clip, after: edge == .tail)
    }

    private func allowedDelta(_ edge: ClipEdge, _ proposed: Double) -> Double {
        if let n = rollNeighbor(edge) {
            let range = edge == .head ? timeline.rollRange(left: n, right: clip) : timeline.rollRange(left: clip, right: n)
            return min(max(proposed, range.lowerBound), range.upperBound)
        }
        return timeline.clampedTrim(clip, edge: edge, delta: proposed)
    }

    private func trimHandle(_ edge: ClipEdge) -> some View {
        let rolling = rollNeighbor(edge) != nil
        return Rectangle()
            .fill(rolling ? Color.orange.opacity(0.9) : (isSelected ? FCP.selection.opacity(0.9) : (timeline.tool == .trim ? Color.white.opacity(0.3) : Color.clear)))
            .frame(width: 7)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard handlesEnabled else { return }
                        let delta = allowedDelta(edge, value.translation.width / timeline.zoom)
                        if edge == .head { headTrim = delta * timeline.zoom } else { tailTrim = delta * timeline.zoom }
                    }
                    .onEnded { value in
                        let delta = value.translation.width / timeline.zoom
                        headTrim = 0
                        tailTrim = 0
                        guard handlesEnabled else { return }
                        if let n = rollNeighbor(edge) {
                            if edge == .head { timeline.roll(left: n.id, right: clip.id, delta: delta) }
                            else { timeline.roll(left: clip.id, right: n.id, delta: delta) }
                        } else {
                            timeline.trim(clip.id, edge: edge, delta: delta)
                        }
                    }
            )
    }
}

// MARK: - Inspector

struct InspectorView: View {
    enum Tab: String, CaseIterable { case video = "Video", color = "Color", audio = "Audio", info = "Info" }

    @Environment(TimelineModel.self) private var timeline
    @Environment(MediaLibrary.self) private var library
    @AppStorage("khcutpro.inspectorTab") private var selectedTab = Tab.video.rawValue

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Inspector") { EmptyView() }
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(8)

            if let clip = timeline.selectedClip {
                ScrollView {
                    VStack(spacing: 0) {
                        switch Tab(rawValue: selectedTab) ?? .video {
                        case .video:
                            if clip.isTitle {
                                Text(clip.title?.isCaption == true
                                     ? "Caption Track · edit text, font, size, and style below."
                                     : "Edit the selected title below.")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(FCP.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                TitleEditor(clip: clip)
                            } else {
                                videoSections(clip)
                            }
                        case .color:
                            if clip.isTitle { note("Atur warna teks atau latar caption di tab Video.") }
                            else { colorSections(clip) }
                        case .audio:
                            if clip.isTitle { note("Caption dan judul tidak memiliki track audio.") }
                            else { audioSections(clip) }
                        case .info:
                            infoSection(asset: clip.asset, clip: clip)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if let asset = library.selectedAsset {
                ScrollView { VStack(spacing: 0) { infoSection(asset: asset, clip: nil); AssetMetadataSection(asset: asset) } }
            } else {
                Spacer()
                Text("Tidak ada yang dipilih")
                    .font(.system(size: 11))
                    .foregroundStyle(FCP.secondary)
                Spacer()
            }
        }
        .background(FCP.panel)
        .onChange(of: timeline.selectedClipID) { _, id in
            if timeline.clip(id)?.isTitle == true { selectedTab = Tab.video.rawValue }
        }
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<TimelineClip, Double>) -> Binding<Double> {
        Binding(get: { timeline.clip(id)?[keyPath: keyPath] ?? 0 },
                set: { value in timeline.updateClip(id) { $0[keyPath: keyPath] = value } })
    }

    @ViewBuilder
    private func videoSections(_ clip: TimelineClip) -> some View {
        if clip.isAdjustmentLayer {
            InspectorSection(title: "Adjustment Layer") {
                Label("Color changes affect visible layers below this clip.", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10))
                    .foregroundStyle(FCP.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AnimatedSlider(clipID: clip.id, property: .opacity)
            }
        } else if clip.asset.fileType == .video || clip.asset.fileType == .image || clip.multicam != nil {
            InspectorSection(title: "Compositing") {
                if clip.asset.fileType == .video {
                    Toggle("Hapus Latar (Person)", isOn: Binding(
                        get: { timeline.clip(clip.id)?.backgroundRemoval == true },
                        set: { enabled in
                            timeline.checkpoint()
                            timeline.updateClip(clip.id) { $0.backgroundRemoval = enabled ? true : nil }
                        }))
                    .controlSize(.small)
                    .help("Memisahkan orang dari latar dengan Vision; proses per frame lebih berat.")
                }
                if clip.asset.fileType == .image || clip.asset.fileType == .video {
                    Button("Terapkan Ken Burns (Pan & Zoom)") { timeline.applyKenBurns(to: clip.id) }
                        .controlSize(.small)
                        .help("Beri gerakan zoom dan pan halus sepanjang klip.")
                }
                HStack {
                    Text("Blend Mode").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { timeline.clip(clip.id)?.blend ?? .normal },
                        set: { mode in timeline.checkpoint(); timeline.updateClip(clip.id) { $0.blend = mode } })) {
                        ForEach(BlendMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                AnimatedSlider(clipID: clip.id, property: .opacity)
            }
            InspectorSection(title: "Transform") {
                AnimatedSlider(clipID: clip.id, property: .scale)
                AnimatedSlider(clipID: clip.id, property: .rotation)
                AnimatedSlider(clipID: clip.id, property: .positionX)
                AnimatedSlider(clipID: clip.id, property: .positionY)
                Button("Reset Transform") {
                    timeline.resetProperties(clip.id, [.scale, .rotation, .positionX, .positionY, .opacity])
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            InspectorSection(title: "Crop") {
                AnimatedSlider(clipID: clip.id, property: .cropLeft)
                AnimatedSlider(clipID: clip.id, property: .cropRight)
                AnimatedSlider(clipID: clip.id, property: .cropTop)
                AnimatedSlider(clipID: clip.id, property: .cropBottom)
                Button("Reset Crop") {
                    timeline.resetProperties(clip.id, [.cropLeft, .cropRight, .cropTop, .cropBottom])
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            StabilizerSection(clip: clip)
            if clip.lane != 0 { TrackerSection(clip: clip) }
            InspectorSection(title: "Keyer (Green Screen)") {
                Toggle("Enable Keyer", isOn: boolBinding(clip.id, \.keyer.enabled)).controlSize(.small)
                if clip.keyer.enabled {
                    HStack {
                        Text("Warna kunci").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                        ColorPicker("", selection: Binding(
                            get: { Color(hue: timeline.clip(clip.id)?.keyer.hue ?? 0.33, saturation: 1, brightness: 1) },
                            set: { color in
                                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .green
                                timeline.checkpoint()
                                timeline.updateClip(clip.id) { $0.keyer.hue = Double(ns.hueComponent) }
                            })).labelsHidden()
                        Spacer()
                    }
                    InspectorSlider(label: "Tolerance", value: binding(clip.id, \.keyer.tolerance), range: 0...0.4) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Softness", value: binding(clip.id, \.keyer.softness), range: 0...0.4) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Min Sat", value: binding(clip.id, \.keyer.minSaturation), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Spill", value: binding(clip.id, \.keyer.spill), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Choke", value: binding(clip.id, \.keyer.choke), range: 0...10) { String(format: "%.1f px", $0) }
                    InspectorSlider(label: "Feather", value: binding(clip.id, \.keyer.feather), range: 0...20) { String(format: "%.1f px", $0) }
                    Toggle("Show Matte", isOn: boolBinding(clip.id, \.keyer.showMatte)).controlSize(.small)
                    Toggle("Invert", isOn: boolBinding(clip.id, \.keyer.invert)).controlSize(.small)
                }
            }
            InspectorSection(title: "Mask") {
                Toggle("Enable Mask", isOn: boolBinding(clip.id, \.mask.enabled)).controlSize(.small)
                if clip.mask.enabled {
                    Picker("", selection: Binding(
                        get: { timeline.clip(clip.id)?.mask.shape ?? .ellipse },
                        set: { shape in timeline.checkpoint(); timeline.updateClip(clip.id) { $0.mask.shape = shape } })) {
                        ForEach(MaskSpec.Shape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    InspectorSlider(label: "Center X", value: binding(clip.id, \.mask.centerX), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Center Y", value: binding(clip.id, \.mask.centerY), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Width", value: binding(clip.id, \.mask.width), range: 0.05...1.5) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Height", value: binding(clip.id, \.mask.height), range: 0.05...1.5) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Feather", value: binding(clip.id, \.mask.feather), range: 0...1) { String(format: "%.2f", $0) }
                    Toggle("Invert", isOn: boolBinding(clip.id, \.mask.invert)).controlSize(.small)
                }
            }
            KeyframeCurveSection(clip: clip)
        } else {
            note("Klip audio tidak punya properti video.")
        }
    }

    private func boolBinding(_ id: UUID, _ keyPath: WritableKeyPath<TimelineClip, Bool>) -> Binding<Bool> {
        Binding(get: { timeline.clip(id)?[keyPath: keyPath] ?? false },
                set: { value in timeline.checkpoint(); timeline.updateClip(id) { $0[keyPath: keyPath] = value } })
    }

    private func wheelBinding(_ id: UUID, _ keyPath: WritableKeyPath<ColorGrade, ColorWheel>) -> Binding<ColorWheel> {
        Binding(get: { timeline.clip(id)?.grade[keyPath: keyPath] ?? ColorWheel() },
                set: { value in timeline.updateClip(id) { $0.grade[keyPath: keyPath] = value } })
    }

    @ViewBuilder
    private func colorSections(_ clip: TimelineClip) -> some View {
        if clip.asset.fileType == .video || clip.asset.fileType == .image || clip.isAdjustmentLayer {
            let id = clip.id
            if !clip.isAdjustmentLayer, clip.asset.fileType == .video {
                InspectorSection(title: "Scopes") { ScopesView() }
                InspectorSection(title: "Color Management") {
                HStack {
                    Text("Input").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { timeline.clip(id)?.inputSpace ?? .rec709 },
                        set: { space in timeline.checkpoint(); timeline.updateClip(id) { $0.inputSpace = space } })) {
                        ForEach(InputColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    .labelsHidden().controlSize(.small)
                }
                HStack {
                    Text("Output").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                    Picker("", selection: Binding(get: { timeline.colorManagement }, set: { timeline.setColorManagement($0) })) {
                        ForEach(ColorManagementMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                }
                Text("Input: ruang warna kamera (mis. S-Log3). Output berlaku untuk seluruh project dan dipakai juga saat export. Transformasi memakai cube 65³ dan kurva ACES hasil pendekatan, bukan RRT resmi.")
                    .font(.system(size: 9)).foregroundStyle(FCP.secondary)
            }
            NodeStrip(clip: clip)

            InspectorSection(title: "Color Wheels") {
                Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        ColorWheelView(title: "Lift", wheel: wheelBinding(id, \.lift)) { timeline.checkpoint() }
                        ColorWheelView(title: "Gamma", wheel: wheelBinding(id, \.gamma)) { timeline.checkpoint() }
                    }
                    GridRow {
                        ColorWheelView(title: "Gain", wheel: wheelBinding(id, \.gain)) { timeline.checkpoint() }
                        ColorWheelView(title: "Offset", wheel: wheelBinding(id, \.offset)) { timeline.checkpoint() }
                    }
                }
            }

            InspectorSection(title: "Color Adjustments") {
                InspectorSlider(label: "Exposure", value: binding(id, \.grade.exposure), range: -3...3) { String(format: "%+.2f EV", $0) }
                InspectorSlider(label: "Contrast", value: binding(id, \.grade.contrast), range: 0.5...1.5) { String(format: "%.2f", $0) }
                InspectorSlider(label: "Saturation", value: binding(id, \.grade.saturation), range: 0...2) { String(format: "%.2f", $0) }
                InspectorSlider(label: "Temperature", value: binding(id, \.grade.temperature), range: -1...1) { String(format: "%+.2f", $0) }
                InspectorSlider(label: "Tint", value: binding(id, \.grade.tint), range: -1...1) { String(format: "%+.2f", $0) }
            }

            InspectorSection(title: "Look Up Table") {
                HStack {
                    Text(clip.grade.lut?.name ?? "Tidak ada LUT")
                        .font(.system(size: 11))
                        .foregroundStyle(clip.grade.lut == nil ? FCP.secondary : .white)
                        .lineLimit(1)
                    Spacer()
                    if clip.grade.lut != nil {
                        Button("Remove") {
                            timeline.checkpoint()
                            timeline.updateClip(id) { $0.grade.lut = nil }
                        }
                        .controlSize(.small)
                    }
                    Button("Load .cube…") { timeline.pickLUT() }
                        .controlSize(.small)
                }
            }

            InspectorSection(title: "Secondary — Qualifier") {
                Toggle("Enable Qualifier", isOn: boolBinding(id, \.grade.secondary.qualifier.enabled)).controlSize(.small)
                if clip.grade.secondary.qualifier.enabled {
                    Toggle("Show Mask", isOn: boolBinding(id, \.grade.secondary.qualifier.showMask)).controlSize(.small)
                    Toggle("Invert", isOn: boolBinding(id, \.grade.secondary.qualifier.invert)).controlSize(.small)
                    InspectorSlider(label: "Hue", value: binding(id, \.grade.secondary.qualifier.hueCenter), range: 0...1) { String(format: "%.0f°", $0 * 360) }
                    InspectorSlider(label: "Hue Width", value: binding(id, \.grade.secondary.qualifier.hueWidth), range: 0...0.5) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Hue Soft", value: binding(id, \.grade.secondary.qualifier.hueSoftness), range: 0...0.5) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Sat Min", value: binding(id, \.grade.secondary.qualifier.satMin), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Sat Max", value: binding(id, \.grade.secondary.qualifier.satMax), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Lum Min", value: binding(id, \.grade.secondary.qualifier.lumMin), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Lum Max", value: binding(id, \.grade.secondary.qualifier.lumMax), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Softness", value: binding(id, \.grade.secondary.qualifier.satSoftness), range: 0...0.5) { String(format: "%.2f", $0) }
                }
            }

            InspectorSection(title: "Secondary — Power Window") {
                Toggle("Enable Window", isOn: boolBinding(id, \.grade.secondary.window.enabled)).controlSize(.small)
                if clip.grade.secondary.window.enabled {
                    Toggle("Invert", isOn: boolBinding(id, \.grade.secondary.window.invert)).controlSize(.small)
                    InspectorSlider(label: "Center X", value: binding(id, \.grade.secondary.window.centerX), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Center Y", value: binding(id, \.grade.secondary.window.centerY), range: 0...1) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Width", value: binding(id, \.grade.secondary.window.width), range: 0.05...1.5) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Height", value: binding(id, \.grade.secondary.window.height), range: 0.05...1.5) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Softness", value: binding(id, \.grade.secondary.window.softness), range: 0...1) { String(format: "%.2f", $0) }
                }
            }

            if clip.grade.secondary.isActive {
                InspectorSection(title: "Secondary — Adjustment") {
                    InspectorSlider(label: "Hue Shift", value: binding(id, \.grade.secondary.hueShift), range: -0.5...0.5) { String(format: "%+.0f°", $0 * 360) }
                    InspectorSlider(label: "Saturation", value: binding(id, \.grade.secondary.saturation), range: 0...2) { String(format: "%.2f", $0) }
                    InspectorSlider(label: "Brightness", value: binding(id, \.grade.secondary.brightness), range: -0.5...0.5) { String(format: "%+.2f", $0) }
                }
            }

            Button("Reset All Color") {
                timeline.checkpoint()
                timeline.updateClip(id) { $0.grade = ColorGrade() }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(10)
        } else {
            note("Klip audio tidak punya properti warna.")
        }
    }

    @ViewBuilder
    private func audioSections(_ clip: TimelineClip) -> some View {
        if clip.asset.hasAudio || clip.multicam != nil {
            RoleMixerSection(clip: clip)
            InspectorSection(title: "Volume") {
                AnimatedSlider(clipID: clip.id, property: .volume)
                Toggle("Mute", isOn: Binding(
                    get: { clip.isMuted },
                    set: { muted in
                        timeline.checkpoint()
                        timeline.updateClip(clip.id) { $0.isMuted = muted }
                    }))
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            AudioFXSection(clip: clip)
            InspectorSection(title: "Fades") {
                InspectorSlider(label: "Fade In", value: binding(clip.id, \.fadeIn), range: 0...10) { String(format: "%.1fs", $0) }
                InspectorSlider(label: "Fade Out", value: binding(clip.id, \.fadeOut), range: 0...10) { String(format: "%.1fs", $0) }
            }
        } else {
            note("Klip ini tidak punya audio.")
        }
    }

    private func infoSection(asset: MediaAsset, clip: TimelineClip?) -> some View {
        InspectorSection(title: "Info") {
            infoRow("Name", asset.fileName)
            infoRow("Type", asset.fileType.rawValue.capitalized)
            infoRow("Source", asset.originalApp)
            if asset.duration > 0 { infoRow("Duration", timecodeString(asset.duration)) }
            if asset.naturalSize != .zero { infoRow("Size", "\(Int(asset.naturalSize.width)) × \(Int(asset.naturalSize.height))") }
            if asset.fileType == .video || asset.fileType == .audio { infoRow("Audio", asset.hasAudio ? "Ya" : "Tidak ada") }
            if let clip {
                infoRow("Clip start", timecodeString(clip.startTime))
                infoRow("Clip length", timecodeString(clip.duration))
                infoRow("Source in", timecodeString(clip.offsetInAsset))
            }
            if asset.isOffline { infoRow("Status", "Media offline") }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(FCP.secondary).frame(width: 72, alignment: .leading)
            Text(value).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(FCP.secondary)
            .padding(16)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(FCP.header)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 8, content: content)
                    .padding(10)
            }
        }
    }
}

struct InspectorSlider: View {
    @Environment(TimelineModel.self) private var timeline
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(FCP.secondary)
                .frame(width: 66, alignment: .leading)
            Slider(value: $value, in: range) { editing in
                if editing { timeline.checkpoint() }
            }
            .controlSize(.small)
            Text(format(value))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }
}
