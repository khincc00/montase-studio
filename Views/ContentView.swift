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
    @AppStorage("khcutpro.shortcut.select") private var selectShortcut = "a"
    @AppStorage("khcutpro.shortcut.trim") private var trimShortcut = "t"
    @AppStorage("khcutpro.shortcut.blade") private var bladeShortcut = "b"
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("PROJECT")
                HStack(spacing: 7) {
                    Menu {
                        Button("Open Project…", systemImage: "folder") { library.openProject(timeline: timeline) }
                        Button("Save Project", systemImage: "square.and.arrow.down") { library.saveProject(timeline: timeline) }
                        Button("Save Project As…", systemImage: "doc.badge.plus") { library.saveProject(timeline: timeline, saveAs: true) }
                        Divider()
                        Button("Versions…", systemImage: "clock.arrow.circlepath") { timeline.isSnapshotsPresented = true }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "film.stack").foregroundStyle(FCP.selection)
                            Text(library.projectName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 115, alignment: .leading)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    .menuStyle(.borderlessButton)
                    Button { library.isImporterPresented = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Import Media (⌘I)")
                }
            }
            .frame(width: 180, alignment: .leading)

            toolbarDivider

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("WORKSPACE")
                HStack(spacing: 3) {
                    ForEach(EditorWorkspace.presets) { preset in
                        Button { applyWorkspace(preset) } label: {
                            Label(preset.title, systemImage: preset.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 8)
                                .frame(height: 25)
                                .background(currentWorkspace == preset ? Color.white.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(currentWorkspace == preset ? .white : FCP.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { isCustomizationPresented = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 26, height: 25)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Customize panels and appearance")
                }
            }
            .frame(width: 315, alignment: .leading)

            toolbarDivider

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("EDIT")
                HStack(spacing: 5) {
                    ForEach(EditTool.allCases, id: \.self) { tool in
                        Button { timeline.tool = tool } label: {
                            Image(systemName: tool.icon)
                                .frame(width: 25, height: 25)
                                .background(timeline.tool == tool ? FCP.selection.opacity(0.22) : Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(timeline.tool == tool ? FCP.selection : .white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("\(tool.title) (\(shortcut(for: tool)))")
                    }
                    Button { isEffectsPresented = true } label: {
                        Label("Titles & FX", systemImage: "sparkles")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 25)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isEffectsPresented) { EffectsGallery() }
                    Button { timeline.addAdjustmentLayer() } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 25, height: 25)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Add Adjustment Layer above selected clips or at the playhead")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            toolbarDivider

            VStack(alignment: .trailing, spacing: 4) {
                sectionLabel("PLAYBACK")
                HStack(spacing: 8) {
                    Button { transport.step(frames: -1) } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .help("Previous Frame")
                    Button { transport.togglePlay() } label: {
                        Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(FCP.selection)
                    }
                    .help("Play / Pause (Space)")
                    Button { transport.step(frames: 1) } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .help("Next Frame")
                    TimecodeText(size: 12, timelineOnly: true)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.leading, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 185, alignment: .trailing)

            toolbarDivider

            VStack(alignment: .trailing, spacing: 4) {
                sectionLabel("DELIVERY")
                HStack(spacing: 8) {
                    Button { timeline.presentExport() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .frame(height: 27)
                            .background(FCP.selection, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.black.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .disabled(timeline.isExporting)
                    .help("Export Movie (⌘E)")
                }
            }
            .frame(width: 95, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(FCP.panel)
        .sheet(isPresented: $isCustomizationPresented) { WorkspaceCustomizationView() }
    }

    private var toolbarDivider: some View {
        Rectangle().fill(FCP.border).frame(width: 1, height: 32).padding(.horizontal, 12)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold))
            .tracking(1)
            .foregroundStyle(FCP.secondary.opacity(0.85))
    }

    private func shortcut(for tool: EditTool) -> String {
        switch tool {
        case .select: selectShortcut.uppercased()
        case .trim: trimShortcut.uppercased()
        case .blade: bladeShortcut.uppercased()
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
