import SwiftUI

// MARK: - Main window — layout mengikuti Final Cut Pro:
// Browser | Viewer | Inspector di atas, Timeline memenuhi bagian bawah.
struct ContentView: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(MediaLibrary.self) private var library
    @Environment(Transport.self) private var transport
    @AppStorage("khcutpro.showBrowser") private var showBrowser = true
    @AppStorage("khcutpro.showViewer") private var showViewer = true
    @AppStorage("khcutpro.showInspector") private var showInspector = true
    @AppStorage("khcutpro.showTimeline") private var showTimeline = true
    @AppStorage("khcutpro.inspectorTab") private var inspectorTab = InspectorView.Tab.video.rawValue
    @AppStorage("khcutpro.accent") private var accent = EditorAccent.amber.rawValue
    private let shortcuts = ShortcutStore.shared
    @State private var isCustomizationPresented = false
    @State private var isEffectsPresented = false

    var body: some View {
        @Bindable var library = library
        @Bindable var timeline = timeline

        VStack(spacing: 0) {
            workspaceBar
            Rectangle().fill(FCP.border).frame(height: 1)
            VSplitView {
                if showBrowser || showViewer || showInspector {
                    HSplitView {
                        if showBrowser {
                            BrowserView()
                                .frame(minWidth: 220, idealWidth: 290, maxWidth: 420)
                        }
                        if showViewer {
                            ViewerView()
                                .frame(minWidth: 340, idealWidth: 640)
                        }
                        if showInspector {
                            InspectorView()
                                .frame(minWidth: 230, idealWidth: 290, maxWidth: 380)
                        }
                    }
                    .frame(minHeight: 280, idealHeight: 440)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 26))
                            .foregroundStyle(FCP.secondary)
                        Text("Semua panel disembunyikan")
                            .font(.system(size: 13, weight: .semibold))
                        Button("Tampilkan Viewer") { showViewer = true }
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FCP.background)
                }

                if showTimeline {
                    TimelinePanel()
                        .frame(minHeight: 180, idealHeight: 280)
                }
            }
        }
        .background(FCP.background)
        .preferredColorScheme(.dark)
        .tint(EditorAccent(rawValue: accent)?.color ?? EditorAccent.amber.color)
        .sheet(isPresented: $timeline.isExportSheetPresented) { ExportSheet() }
        .sheet(isPresented: $timeline.isSnapshotsPresented) { SnapshotsSheet() }
        .fileImporter(isPresented: $library.isImporterPresented,
                      allowedContentTypes: AssetCompatibilityService.allowedContentTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await library.importFiles(urls, into: timeline) }
            case .failure(let error):
                library.alertMessage = error.localizedDescription
            }
        }
        .alert("KHCutPro", isPresented: Binding(get: { library.alertMessage != nil },
                                                set: { if !$0 { library.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.alertMessage ?? "")
        }
        .alert("KHCutPro", isPresented: Binding(get: { timeline.statusMessage != nil },
                                                set: { if !$0 { timeline.statusMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(timeline.statusMessage ?? "")
        }
        .overlay {
            if library.isSyncing || timeline.isTranscribing {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(timeline.isTranscribing ? "Mentranskripsi audio…" : "Menyinkronkan audio angle…").font(.system(size: 12))
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var workspaceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // KLASIFIKASI 1: MEDIA & PROYEK
                projectSection

                toolbarDivider

                // KLASIFIKASI 2: RUANG KERJA & PANEL
                workspaceSection

                toolbarDivider

                // KLASIFIKASI 3: ALAT EDIT
                editSection

                toolbarDivider

                // KLASIFIKASI 4: EFEK & KREATIF
                effectsSection

                toolbarDivider

                // KLASIFIKASI 5: NAVIGASI & MONITOR
                transportSection

                toolbarDivider

                // KLASIFIKASI 6: EKSPOR & HASIL
                deliverySection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 64)
        .background(FCP.panel)
        .sheet(isPresented: $isCustomizationPresented) { WorkspaceCustomizationView() }
    }

    // MARK: - Klasifikasi 1: Media & Proyek
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("PROYEK & MEDIA", icon: "folder.fill")
            HStack(spacing: 5) {
                Menu {
                    Button("Buka Proyek…", systemImage: "folder") { library.openProject(timeline: timeline) }
                    Button("Simpan Proyek", systemImage: "square.and.arrow.down") { library.saveProject(timeline: timeline) }
                    Button("Simpan Proyek Sebagai…", systemImage: "doc.badge.plus") { library.saveProject(timeline: timeline, saveAs: true) }
                    Divider()
                    Button("Riwayat Versi…", systemImage: "clock.arrow.circlepath") { timeline.isSnapshotsPresented = true }
                    Button("Ambil Snapshot Saat Ini", systemImage: "camera") { timeline.takeSnapshot(named: "") }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack")
                            .foregroundStyle(FCP.selection)
                            .font(.system(size: 11))
                        Text(library.projectName.isEmpty ? "Proyek Baru" : library.projectName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(FCP.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .help("Menu Proyek & Snapshot (⌘O, ⌘S)")

                Button {
                    library.isImporterPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 10.5))
                        Text("Impor")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("Impor Media ke Library (⌘I)")

                Menu {
                    Button(timeline.useProxies ? "Gunakan Media Asli (Full Res)" : "Aktifkan Proxy Ringan") {
                        timeline.setUseProxies(!timeline.useProxies)
                    }
                    Divider()
                    Button("Buat Proxy untuk Semua Video") {
                        Task { await library.generateAllProxies(timeline: timeline) }
                    }
                    Toggle("Proxy Otomatis (Media 4K+)", isOn: Binding(get: { library.autoProxy }, set: { library.autoProxy = $0 }))
                    Divider()
                    if let folder = library.watchedFolder {
                        Button("Berhenti Memantau “\(folder.lastPathComponent)”") { library.stopWatching() }
                    } else {
                        Button("Pantau Folder (Watch Folder)…") { library.chooseWatchFolder(timeline: timeline) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(timeline.useProxies ? Color.cyan : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(timeline.useProxies ? "Proxy" : "Orig")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(timeline.useProxies ? Color.cyan : FCP.secondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .background(timeline.useProxies ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(timeline.useProxies ? Color.cyan.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .help(timeline.useProxies ? "Playback memakai Proxy (Cepat & Hemat Daya)" : "Playback memakai Media Asli (Resolusi Penuh)")
            }
        }
    }

    // MARK: - Klasifikasi 2: Ruang Kerja & Panel
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("RUANG KERJA & PANEL", icon: "macwindow")
            HStack(spacing: 5) {
                // Presets
                HStack(spacing: 2) {
                    ForEach(EditorWorkspace.presets) { preset in
                        Button {
                            applyWorkspace(preset)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 9.5))
                                Text(preset.title)
                                    .font(.system(size: 10.5, weight: currentWorkspace == preset ? .semibold : .regular))
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 28)
                            .background(currentWorkspace == preset ? FCP.selection.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(currentWorkspace == preset ? FCP.selection.opacity(0.5) : Color.clear, lineWidth: 1))
                            .foregroundStyle(currentWorkspace == preset ? FCP.selection : .white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Tata Letak: \(preset.title)")
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))

                // Panel Toggles
                HStack(spacing: 2) {
                    panelToggleButton(icon: "sidebar.left", isOn: $showBrowser, title: "Browser")
                    panelToggleButton(icon: "play.rectangle", isOn: $showViewer, title: "Viewer")
                    panelToggleButton(icon: "sidebar.right", isOn: $showInspector, title: "Inspector")
                    panelToggleButton(icon: "rectangle.bottomthird.inset.filled", isOn: $showTimeline, title: "Timeline")
                }
                .padding(2)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))

                // Settings
                Button {
                    isCustomizationPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 28)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .foregroundStyle(FCP.secondary)
                }
                .buttonStyle(.plain)
                .help("Kustomisasi Panel & Warna Aksen")
            }
        }
    }

    private func panelToggleButton(icon: String, isOn: Binding<Bool>, title: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .frame(width: 24, height: 24)
                .background(isOn.wrappedValue ? Color.white.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isOn.wrappedValue ? FCP.selection.opacity(0.5) : Color.clear, lineWidth: 1))
                .foregroundStyle(isOn.wrappedValue ? FCP.selection : FCP.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Tampilkan / Sembunyikan Panel \(title)")
    }

    // MARK: - Klasifikasi 3: Alat Edit
    private var editSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("ALAT EDIT", icon: "wrench.and.screwdriver.fill")
            HStack(spacing: 5) {
                // Edit Tools
                HStack(spacing: 2) {
                    ForEach(EditTool.allCases, id: \.self) { tool in
                        Button {
                            timeline.tool = tool
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 10.5))
                                Text(shortcut(for: tool))
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(timeline.tool == tool ? FCP.selection : FCP.secondary.opacity(0.7))
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 28)
                            .background(timeline.tool == tool ? FCP.selection.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(timeline.tool == tool ? FCP.selection.opacity(0.6) : Color.clear, lineWidth: 1))
                            .foregroundStyle(timeline.tool == tool ? FCP.selection : .white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("\(tool.title) Tool (\(shortcut(for: tool)))")
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))

                // Actions: Blade di Playhead & Marker
                HStack(spacing: 3) {
                    Button {
                        timeline.splitAtPlayhead()
                    } label: {
                        Image(systemName: "scissors")
                            .font(.system(size: 11))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Potong / Blade di Playhead (⌘B)")

                    Button {
                        timeline.addMarker()
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Tambah Marker di Playhead (\(shortcuts.label(for: .addMarker)))")
                }

                // Three-Point Insertions
                HStack(spacing: 2) {
                    insertionButton(title: "Connect", icon: "arrow.down.to.line.compact", shortcut: shortcuts.label(for: .connect)) {
                        transport.perform(.connect)
                    }
                    insertionButton(title: "Insert", icon: "arrow.down.right.and.arrow.up.left", shortcut: shortcuts.label(for: .insert)) {
                        transport.perform(.insert)
                    }
                    insertionButton(title: "Append", icon: "arrow.right.to.line", shortcut: shortcuts.label(for: .append)) {
                        transport.perform(.append)
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
        }
    }

    private func insertionButton(title: String, icon: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .frame(width: 25, height: 24)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(library.selectedAsset != nil ? .white.opacity(0.9) : FCP.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(library.selectedAsset == nil)
        .help("\(title) media dari Browser ke Timeline (\(shortcut))")
    }

    // MARK: - Klasifikasi 4: Efek & Komposisi
    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("EFEK & KREATIF", icon: "sparkles")
            HStack(spacing: 4) {
                Button {
                    isEffectsPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5))
                            .foregroundStyle(FCP.selection)
                        Text("Judul & FX")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEffectsPresented) { EffectsGallery() }
                .help("Buka Galeri Judul, Efek, Transisi, dan Filter Look")

                Button {
                    timeline.addAdjustmentLayer()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.2.layers.3d")
                            .font(.system(size: 10))
                        Text("+ Adj")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Tambah Adjustment Layer di atas klip timeline")

                Button {
                    showInspector = true
                    inspectorTab = InspectorView.Tab.color.rawValue
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Buka Scopes & Color Grading Inspector")
            }
        }
    }

    // MARK: - Klasifikasi 5: Navigasi & Monitor
    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("NAVIGASI", icon: "play.circle.fill")
            HStack(spacing: 5) {
                HStack(spacing: 1) {
                    transportButton("backward.end.fill", help: "Lompat ke Awal") { transport.goToStart() }
                    transportButton("backward.frame.fill", help: "Mundur 1 Frame (←)") { transport.step(frames: -1) }

                    Button {
                        transport.togglePlay()
                    } label: {
                        Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 24)
                            .background(transport.isPlaying ? FCP.selection : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(transport.isPlaying ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .help("Play / Pause (Space) • J K L untuk shuttle")

                    transportButton("forward.frame.fill", help: "Maju 1 Frame (→)") { transport.step(frames: 1) }
                    transportButton("forward.end.fill", help: "Lompat ke Akhir") { transport.goToEnd() }
                }
                .padding(2)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.06), lineWidth: 1))

                // LCD Broadcast Timecode Display
                HStack(spacing: 6) {
                    TimecodeText(size: 12, timelineOnly: true)
                        .foregroundStyle(Color.green.opacity(0.95))

                    FrameRateMenu()
                }
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.25), lineWidth: 1))
                .help("Posisi Playhead Timeline Saat Ini")
            }
        }
    }

    private func transportButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .frame(width: 20, height: 24)
                .background(Color.clear)
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Klasifikasi 6: Ekspor & Hasil
    private var deliverySection: some View {
        VStack(alignment: .trailing, spacing: 3) {
            sectionHeader("EKSPOR", icon: "arrow.up.circle.fill")
            HStack(spacing: 4) {
                Button {
                    timeline.presentExport()
                } label: {
                    HStack(spacing: 5) {
                        if timeline.isExporting {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 10.5))
                        }
                        Text(timeline.isExporting ? "Mengekspor…" : "Ekspor")
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(FCP.selection, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(timeline.isExporting)
                .help("Ekspor Film Master (⌘E)")

                Menu {
                    Button("Ekspor Film Master…", systemImage: "film") { timeline.presentExport() }
                    Button("Ekspor FCPXML…", systemImage: "doc.text") { timeline.presentExportFCPXML() }
                    Divider()
                    Button("Simpan Frame Saat Ini (PNG)…", systemImage: "photo") { timeline.exportCurrentFramePNG() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 28)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .foregroundStyle(FCP.secondary)
                }
                .menuStyle(.borderlessButton)
                .help("Pilihan Format Ekspor & Simpan Frame")
            }
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(FCP.border)
            .frame(width: 1, height: 32)
            .padding(.horizontal, 3)
    }

    private func sectionHeader(_ title: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .bold))
            }
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(FCP.secondary.opacity(0.75))
    }

    private func shortcut(for tool: EditTool) -> String {
        switch tool {
        case .select: shortcuts.label(for: .toolSelect)
        case .trim: shortcuts.label(for: .toolTrim)
        case .blade: shortcuts.label(for: .toolBlade)
        }
    }

    private var currentWorkspace: EditorWorkspace {
        guard showViewer, showTimeline else { return .custom }
        if showBrowser && showInspector {
            switch inspectorTab {
            case InspectorView.Tab.video.rawValue: return .editing
            case InspectorView.Tab.color.rawValue: return .color
            case InspectorView.Tab.audio.rawValue: return .audio
            default: return .custom
            }
        }
        if !showBrowser && !showInspector { return .review }
        return .custom
    }

    private func applyWorkspace(_ workspace: EditorWorkspace) {
        showBrowser = workspace != .review
        showViewer = true
        showInspector = workspace != .review
        showTimeline = true
        switch workspace {
        case .editing: inspectorTab = InspectorView.Tab.video.rawValue
        case .color: inspectorTab = InspectorView.Tab.color.rawValue
        case .audio: inspectorTab = InspectorView.Tab.audio.rawValue
        case .review, .custom: break
        }
    }

    private enum EditorWorkspace: String, Identifiable {
        case editing, color, audio, review, custom

        static let presets: [EditorWorkspace] = [.editing, .color, .audio, .review]

        var id: String { rawValue }

        var title: String {
            switch self {
            case .editing: "Edit"
            case .color: "Color"
            case .audio: "Audio"
            case .review: "Review"
            case .custom: "Custom"
            }
        }

        var icon: String {
            switch self {
            case .editing: "rectangle.split.3x1"
            case .color: "slider.horizontal.3"
            case .audio: "waveform"
            case .review: "play.rectangle"
            case .custom: "rectangle.3.group"
            }
        }
    }

    private struct WorkspaceCustomizationView: View {
        @Environment(\.dismiss) private var dismiss
        @AppStorage("khcutpro.showBrowser") private var showBrowser = true
        @AppStorage("khcutpro.showViewer") private var showViewer = true
        @AppStorage("khcutpro.showInspector") private var showInspector = true
        @AppStorage("khcutpro.showTimeline") private var showTimeline = true
        @AppStorage("khcutpro.accent") private var accent = EditorAccent.amber.rawValue
        @AppStorage("khcutpro.timelineScale") private var timelineScale = 1.0

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Customize Workspace")
                        .font(.system(size: 19, weight: .bold))
                    Text("Atur panel dan tampilan editor sesuai alur kerja Anda.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("PANELS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Toggle("Media Browser", isOn: $showBrowser)
                    Toggle("Viewer", isOn: $showViewer)
                    Toggle("Inspector", isOn: $showInspector)
                    Toggle("Timeline", isOn: $showTimeline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 10) {
                    Text("ACCENT COLOR")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(EditorAccent.allCases) { option in
                            Button {
                                accent = option.rawValue
                            } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(option.color).frame(width: 12, height: 12)
                                    Text(option.title)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(Color.white.opacity(accent == option.rawValue ? 0.1 : 0.04),
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(accent == option.rawValue ? option.color.opacity(0.8) : FCP.border,
                                                lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Timeline Track Height")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(Int(timelineScale * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $timelineScale, in: 0.75...1.5, step: 0.05)
                        .tint(FCP.selection)
                }

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 480)
            .background(FCP.panel)
            .preferredColorScheme(.dark)
        }
    }
    }
