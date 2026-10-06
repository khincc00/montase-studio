import SwiftUI
import AppKit

@main
struct KhinccCutProApp: App {
    @AppStorage("khcutpro.shortcut.select") private var selectShortcut = "a"
    @AppStorage("khcutpro.shortcut.trim") private var trimShortcut = "t"
    @AppStorage("khcutpro.shortcut.blade") private var bladeShortcut = "b"
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
        _transport = State(initialValue: Transport(timeline: timeline, library: library))
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
                Button("Open Project…") { library.openProject(timeline: timeline) }
                    .keyboardShortcut("o")
                Button("Save Project") { library.saveProject(timeline: timeline) }
                    .keyboardShortcut("s")
                Button("Save Project As…") { library.saveProject(timeline: timeline, saveAs: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Versions…") { timeline.isSnapshotsPresented = true }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Button("Save Version") { timeline.takeSnapshot(named: "") }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Import Media…") { library.isImporterPresented = true }
                    .keyboardShortcut("i")
                Button("Export Movie…") { timeline.presentExport() }
                    .keyboardShortcut("e")
                Button("Export FCPXML…") { timeline.presentExportFCPXML() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Current Frame as PNG…") { timeline.exportCurrentFramePNG() }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { timeline.undo() }
                    .keyboardShortcut("z")
                    .disabled(!timeline.canUndo)
                Button("Redo") { timeline.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!timeline.canRedo)
            }

            CommandMenu("Clip") {
                Button("Connect to Primary Storyline") { transport.perform(.connect) }
                    .keyboardShortcut("q", modifiers: [])
                Button("Insert at Playhead") { transport.perform(.insert) }
                    .keyboardShortcut("w", modifiers: [])
                Button("Append to Storyline") { transport.perform(.append) }
                    .keyboardShortcut("e", modifiers: [])
                Divider()
                Button("Blade") { timeline.splitAtPlayhead() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Delete") { timeline.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(timeline.selectedClipIDs.isEmpty)
                Button("Copy Selected Clips") { timeline.copySelected() }
                    .keyboardShortcut("c")
                    .disabled(timeline.selectedClipIDs.isEmpty)
                Button("Paste Clips at Playhead") { timeline.pasteClips() }
                    .keyboardShortcut("v")
                    .disabled(timeline.clipClipboard.isEmpty)
                Divider()
                Button("New Compound Clip") { timeline.makeCompound() }
                    .keyboardShortcut("g", modifiers: .option)
                Button("Break Apart Compound Clip") { timeline.breakApartSelected() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Open Compound Clip") { timeline.openCompound() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Next Keyframe") { timeline.jumpToKeyframe(forward: true) }
                    .keyboardShortcut("]", modifiers: .option)
                Button("Previous Keyframe") { timeline.jumpToKeyframe(forward: false) }
                    .keyboardShortcut("[", modifiers: .option)
                Divider()
                Button("Close Compound Clip") { timeline.closeCompound() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(timeline.compoundStack.isEmpty)
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
                Button("Tandai Favorit") { if let id = library.selectedAssetID { library.toggleFavorite(id) } }
                    .keyboardShortcut("f", modifiers: [])
                Button("Tolak") { if let id = library.selectedAssetID { library.toggleRejected(id) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Buat Proxy untuk Semua Video") { Task { await library.generateAllProxies(timeline: timeline) } }
                Button(library.watchedFolder == nil ? "Pantau Folder (Watch Folder)…" : "Berhenti Memantau Folder") {
                    if library.watchedFolder == nil { library.chooseWatchFolder(timeline: timeline) } else { library.stopWatching() }
                }
                Button(timeline.useProxies ? "Pakai Media Asli" : "Pakai Proxy") { timeline.setUseProxies(!timeline.useProxies) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
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
                Button("Add Browser Selection as Take") {
                    if let id = timeline.selectedClipID, let asset = library.selectedAsset { timeline.addTake(to: id, asset: asset) }
                    else { timeline.statusMessage = "Pilih klip di timeline dan media di Browser." }
                }
                .keyboardShortcut("y", modifiers: [.command, .option])
                Button("Next Take") { if let id = timeline.selectedClipID { timeline.cycleTake(id, by: 1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Take") { if let id = timeline.selectedClipID { timeline.cycleTake(id, by: -1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Finalize Audition") { if let id = timeline.selectedClipID { timeline.finalizeAudition(id) } }
                    .keyboardShortcut("y", modifiers: [.command, .option, .shift])
            }

            CommandMenu("Multicam") {
                Button("New Multicam Clip from Browser Selection…") { Task { await library.createMulticam(into: timeline) } }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Switch to Angle \(n)") { timeline.switchAngle(n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
                }
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Switch Audio to Angle \(n)") { timeline.switchAngle(n - 1, video: false) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .option)
                }
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Switch Video to Angle \(n)") { timeline.switchAngle(n - 1, audio: false) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
                }
            }

            CommandMenu("Tools") {
                Button("Select") { timeline.tool = .select }
                    .keyboardShortcut(KeyEquivalent(Character(selectShortcut)), modifiers: [])
                Button("Trim") { timeline.tool = .trim }
                    .keyboardShortcut(KeyEquivalent(Character(trimShortcut)), modifiers: [])
                Button("Blade") { timeline.tool = .blade }
                    .keyboardShortcut(KeyEquivalent(Character(bladeShortcut)), modifiers: [])
                Divider()
                ForEach(Array(TrimMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button("Trim: \(mode.title)") { timeline.tool = .trim; timeline.trimMode = mode }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
                Divider()
                Button(timeline.snapping ? "Turn Snapping Off" : "Turn Snapping On") { timeline.snapping.toggle() }
                    .keyboardShortcut("n", modifiers: [])
                Button("Zoom In") { timeline.zoom = min(240, timeline.zoom * 1.5) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { timeline.zoom = max(0.25, timeline.zoom / 1.5) }
                    .keyboardShortcut("-")
            }

            CommandMenu("Mark") {
                Button("Set Range Start") { transport.markIn() }
                    .keyboardShortcut("i", modifiers: [])
                Button("Set Range End") { transport.markOut() }
                    .keyboardShortcut("o", modifiers: [])
                Button("Clear Range") { transport.clearMarks() }
                    .keyboardShortcut("x", modifiers: .option)
                Divider()
                Button("Tambah Marker") { timeline.addMarker() }
                    .keyboardShortcut("m", modifiers: [])
                Button("Marker Berikutnya") { timeline.jumpToMarker(forward: true) }
                    .keyboardShortcut(".", modifiers: .option)
                Button("Marker Sebelumnya") { timeline.jumpToMarker(forward: false) }
                    .keyboardShortcut(",", modifiers: .option)
                Button("Hapus Semua Marker Beat") { timeline.clearBeatMarkers() }
                Button("Hapus Marker di Playhead") {
                    if let m = timeline.markers.first(where: { abs($0.time - timeline.playhead) < 0.1 }) { timeline.removeMarker(m.id) }
                }
            }

            CommandMenu("Playback") {
                Button(transport.isPlaying ? "Pause" : "Play") { transport.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Play Reverse") { transport.shuttle(forward: false) }
                    .keyboardShortcut("j", modifiers: [])
                Button("Pause") { transport.pause() }
                    .keyboardShortcut("k", modifiers: [])
                Button("Play Forward") { transport.shuttle(forward: true) }
                    .keyboardShortcut("l", modifiers: [])
                Divider()
                Button("Previous Frame") { transport.step(frames: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Frame") { transport.step(frames: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous Edit") { timeline.jumpToEdit(forward: false) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Next Edit") { timeline.jumpToEdit(forward: true) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("Go to Start") { transport.goToStart() }
                    .keyboardShortcut(.home, modifiers: [])
                Button("Go to End") { transport.goToEnd() }
                    .keyboardShortcut(.end, modifiers: [])
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage("khcutpro.shortcut.select") private var selectShortcut = "a"
    @AppStorage("khcutpro.shortcut.trim") private var trimShortcut = "t"
    @AppStorage("khcutpro.shortcut.blade") private var bladeShortcut = "b"

    private let shortcutChoices = ["a", "t", "b", "s", "d"]

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                shortcutPicker("Select tool", value: $selectShortcut, excluding: [trimShortcut, bladeShortcut])
                shortcutPicker("Trim tool", value: $trimShortcut, excluding: [selectShortcut, bladeShortcut])
                shortcutPicker("Blade tool", value: $bladeShortcut, excluding: [selectShortcut, trimShortcut])
                Text("Pintasan alat menggunakan tombol tanpa modifier. Pilih tombol berbeda untuk setiap alat.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
        .frame(width: 520, height: 390)
    }

    private func shortcutPicker(_ title: String, value: Binding<String>, excluding: [String]) -> some View {
        Picker(title, selection: value) {
            ForEach(shortcutChoices.filter { !excluding.contains($0) || $0 == value.wrappedValue }, id: \.self) { key in
                Text(key.uppercased()).tag(key)
            }
        }
    }
}
