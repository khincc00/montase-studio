import SwiftUI
import AppKit

@main
struct KhinccCutProApp: App {
    private let shortcuts = ShortcutStore.shared
    @State private var timeline: TimelineModel
    @State private var library: MediaLibrary
    @State private var transport: Transport

    init() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = appIcon
        }
        let timeline = TimelineModel()
        let library = MediaLibrary()
        _timeline = State(initialValue: timeline)
        _library = State(initialValue: library)
        let transport = Transport(timeline: timeline, library: library)
        _transport = State(initialValue: transport)
        DemoProjectInstaller.installIfRequested(timeline: timeline, library: library, transport: transport)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(timeline)
                .environment(library)
                .environment(transport)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Khincc Cut Pro") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [NSApplication.AboutPanelOptionKey.applicationName: "Khincc Cut Pro",
                                  NSApplication.AboutPanelOptionKey.applicationVersion: "1.0"]
                    )
                }
            }

            CommandGroup(replacing: .newItem) {
                item("Open Project…", .openProject) { library.openProject(timeline: timeline) }
                item("Save Project", .saveProject) { library.saveProject(timeline: timeline) }
                item("Save Project As…", .saveProjectAs) { library.saveProject(timeline: timeline, saveAs: true) }
                Divider()
                item("Versions…", .versions) { timeline.isSnapshotsPresented = true }
                item("Save Version", .saveVersion) { timeline.takeSnapshot(named: "") }
                Divider()
                item("Import Media…", .importMedia) { library.isImporterPresented = true }
                item("Export Movie…", .exportMovie) { timeline.presentExport() }
                item("Export FCPXML…", .exportFCPXML) { timeline.presentExportFCPXML() }
                item("Export Current Frame as PNG…", .exportFrame) { timeline.exportCurrentFramePNG() }
            }

            CommandGroup(replacing: .undoRedo) {
                item("Undo", .undo) { timeline.undo() }
                    .disabled(!timeline.canUndo)
                item("Redo", .redo) { timeline.redo() }
                    .disabled(!timeline.canRedo)
            }

            CommandMenu("Clip") {
                item("Connect to Primary Storyline", .connect) { transport.perform(.connect) }
                item("Insert at Playhead", .insert) { transport.perform(.insert) }
                item("Append to Storyline", .append) { transport.perform(.append) }
                Divider()
                item("Blade", .blade) { timeline.splitAtPlayhead() }
                item("Delete", .delete) { timeline.deleteSelected() }
                    .disabled(timeline.selectedClipIDs.isEmpty)
                item("Copy Selected Clips", .copy) { timeline.copySelected() }
                    .disabled(timeline.selectedClipIDs.isEmpty)
                item("Paste Clips at Playhead", .paste) { timeline.pasteClips() }
                    .disabled(timeline.clipClipboard.isEmpty)
                Divider()
                item("New Compound Clip", .newCompound) { timeline.makeCompound() }
                item("Break Apart Compound Clip", .breakApart) { timeline.breakApartSelected() }
                item("Open Compound Clip", .openCompound) { timeline.openCompound() }
                item("Close Compound Clip", .closeCompound) { timeline.closeCompound() }
                    .disabled(timeline.compoundStack.isEmpty)
                Divider()
                item("Next Keyframe", .nextKeyframe) { timeline.jumpToKeyframe(forward: true) }
                item("Previous Keyframe", .previousKeyframe) { timeline.jumpToKeyframe(forward: false) }
            }

            CommandMenu("Trim") {
                item("Trim Start ke Playhead", .trimStart) { timeline.trimStartToPlayhead() }
                item("Trim End ke Playhead", .trimEnd) { timeline.trimEndToPlayhead() }
                item("Trim ke Range In/Out", .trimToRange) { timeline.trimToRange() }
                Divider()
                item("Trim Start −1 Frame", .trimStartBack) { timeline.nudgeTrim(edge: .head, frames: -1) }
                item("Trim Start +1 Frame", .trimStartForward) { timeline.nudgeTrim(edge: .head, frames: 1) }
                item("Trim End −1 Frame", .trimEndBack) { timeline.nudgeTrim(edge: .tail, frames: -1) }
                item("Trim End +1 Frame", .trimEndForward) { timeline.nudgeTrim(edge: .tail, frames: 1) }
            }

            CommandMenu("Efek") {
                ForEach(TitlePreset.allCases, id: \.self) { preset in
                    Button("Tambah Judul: \(preset.title)") { timeline.addTitle(preset) }
                }
                Divider()
                ForEach(TransitionKind.allCases, id: \.self) { kind in
                    Button("Pasang Transisi: \(kind.title)") { timeline.applyTransition(kind) }
                }
                Divider()
                ForEach(LookPreset.allCases, id: \.self) { look in
                    Button("Look: \(look.title)") { timeline.applyLook(look) }
                }
            }

            CommandMenu("Media") {
                item("Tandai Favorit", .toggleFavorite) { if let id = library.selectedAssetID { library.toggleFavorite(id) } }
                item("Tolak", .reject) { if let id = library.selectedAssetID { library.toggleRejected(id) } }
                Divider()
                Button("Buat Proxy untuk Semua Video") { Task { await library.generateAllProxies(timeline: timeline) } }
                Button(library.watchedFolder == nil ? "Pantau Folder (Watch Folder)…" : "Berhenti Memantau Folder") {
                    if library.watchedFolder == nil { library.chooseWatchFolder(timeline: timeline) } else { library.stopWatching() }
                }
                item(timeline.useProxies ? "Pakai Media Asli" : "Pakai Proxy", .toggleProxy) { timeline.setUseProxies(!timeline.useProxies) }
            }

            CommandMenu("Audio") {
                Button("Auto-Duck Musik di Bawah Dialog") { Task { await timeline.autoDuck() } }
                Button("Auto-Sync Audio ke Video") { Task { await timeline.autoSyncAudioToVideo() } }
                Divider()
                Button("Tandai Beat dari Klip Terpilih") { let id = timeline.selectedClipID; Task { await timeline.markBeats(of: id) } }
                Button("Potong Klip Terpilih Sesuai Beat") { timeline.cutToBeats() }
                Divider()
                ForEach(AudioRole.allCases, id: \.self) { role in
                    Button("Peran Klip: \(role.title)") { if let id = timeline.selectedClipID { timeline.setRole(id, role) } }
                }
            }

            CommandMenu("Caption") {
                Button("Buat Caption Otomatis dari Klip Terpilih…") {
                    let id = timeline.selectedClipID
                    Task { await timeline.generateCaptions(for: id) }
                }
                Button("Impor Subtitle (.srt)…") { timeline.importSRT() }
                Button("Ekspor Caption (.srt)…") { timeline.exportSRT() }
            }

            CommandMenu("Audition") {
                item("Add Browser Selection as Take", .addTake) {
                    if let id = timeline.selectedClipID, let asset = library.selectedAsset { timeline.addTake(to: id, asset: asset) }
                    else { timeline.statusMessage = "Pilih klip di timeline dan media di Browser." }
                }
                item("Next Take", .nextTake) { if let id = timeline.selectedClipID { timeline.cycleTake(id, by: 1) } }
                item("Previous Take", .previousTake) { if let id = timeline.selectedClipID { timeline.cycleTake(id, by: -1) } }
                item("Finalize Audition", .finalizeAudition) { if let id = timeline.selectedClipID { timeline.finalizeAudition(id) } }
            }

            CommandMenu("Multicam") {
                item("New Multicam Clip from Browser Selection…", .newMulticam) { Task { await library.createMulticam(into: timeline) } }
                ForEach(AngleScope.allCases, id: \.self) { scope in
                    Divider()
                    ForEach(1...9, id: \.self) { n in
                        item(angleTitle(scope, n), .switchAngle(scope, n)) {
                            timeline.switchAngle(n - 1, video: scope != .audio, audio: scope != .video)
                        }
                    }
                }
            }

            CommandMenu("Tools") {
                item("Select", .toolSelect) { timeline.tool = .select }
                item("Trim", .toolTrim) { timeline.tool = .trim }
                item("Blade", .toolBlade) { timeline.tool = .blade }
                Divider()
                ForEach(TrimMode.allCases, id: \.self) { mode in
                    item("Trim: \(mode.title)", .trimMode(mode)) { timeline.tool = .trim; timeline.trimMode = mode }
                }
                Divider()
                item(timeline.snapping ? "Turn Snapping Off" : "Turn Snapping On", .toggleSnapping) { timeline.snapping.toggle() }
                item("Zoom In", .zoomIn) { timeline.zoom = min(240, timeline.zoom * 1.5) }
                item("Zoom Out", .zoomOut) { timeline.zoom = max(0.25, timeline.zoom / 1.5) }
            }

            CommandMenu("Mark") {
                item("Set Range Start", .markIn) { transport.markIn() }
                item("Set Range End", .markOut) { transport.markOut() }
                item("Clear Range", .clearRange) { transport.clearMarks() }
                Divider()
                item("Tambah Marker", .addMarker) { timeline.addMarker() }
                item("Marker Berikutnya", .nextMarker) { timeline.jumpToMarker(forward: true) }
                item("Marker Sebelumnya", .previousMarker) { timeline.jumpToMarker(forward: false) }
                Button("Hapus Semua Marker Beat") { timeline.clearBeatMarkers() }
                Button("Hapus Marker di Playhead") {
                    if let m = timeline.markers.first(where: { abs($0.time - timeline.playhead) < 0.1 }) { timeline.removeMarker(m.id) }
                }
            }

            CommandMenu("Playback") {
                item(transport.isPlaying ? "Pause" : "Play", .playPause) { transport.togglePlay() }
                item("Play Reverse", .playReverse) { transport.shuttle(forward: false) }
                item("Pause", .pause) { transport.pause() }
                item("Play Forward", .playForward) { transport.shuttle(forward: true) }
                Divider()
                item("Previous Frame", .previousFrame) { transport.step(frames: -1) }
                item("Next Frame", .nextFrame) { transport.step(frames: 1) }
                item("Previous Edit", .previousEdit) { timeline.jumpToEdit(forward: false) }
                item("Next Edit", .nextEdit) { timeline.jumpToEdit(forward: true) }
                item("Go to Start", .goToStart) { transport.goToStart() }
                item("Go to End", .goToEnd) { transport.goToEnd() }
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func item(_ title: String, _ action: ShortcutAction, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).shortcut(action, shortcuts)
    }

    private func angleTitle(_ scope: AngleScope, _ n: Int) -> String {
        switch scope {
        case .both: "Switch to Angle \(n)"
        case .audio: "Switch Audio to Angle \(n)"
        case .video: "Switch Video to Angle \(n)"
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            ShortcutSettingsView()
                .tabItem { Label("Pintasan", systemImage: "keyboard") }
            formatsForm
                .tabItem { Label("Format", systemImage: "film") }
        }
        .frame(width: 640, height: 560)
    }

    private var formatsForm: some View {
        Form {
            Section("Format yang didukung") {
                LabeledContent("Video", value: "mp4, mov (H.264 / HEVC / ProRes), m4v, mxf*, avi*")
                LabeledContent("Audio", value: "wav, aiff, mp3, aac, m4a")
                LabeledContent("Timeline (impor)", value: "FCPXML, Premiere XML (xmeml), EDL")
                LabeledContent("Color", value: "LUT 3D .cube")
                LabeledContent("Export", value: "QuickTime .mov, FCPXML")
            }
            Section {
                Text("*Dibuka lewat AVFoundation, jadi hanya codec bawaan macOS yang bisa diputar. AAF, project native (.prproj, .drp), dan .mogrt belum didukung.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
