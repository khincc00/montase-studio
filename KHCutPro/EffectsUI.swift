import SwiftUI
import Speech

/// Galeri 1-klik: judul, transisi, dan look warna.
struct EffectsGallery: View {
    enum Tab: String, CaseIterable { case titles = "Judul", transitions = "Transisi", looks = "Look", captions = "Caption" }

    @Environment(TimelineModel.self) private var timeline
    @State private var tab: Tab = .titles
    @State private var duration = 1.0
    @State private var titleDuration = 4.0
    @State private var captionLocaleIdentifier = "id-ID"

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .titles:
                HStack {
                    Text("Durasi").font(.caption)
                    Slider(value: $titleDuration, in: 1...15, step: 0.5)
                    Text(String(format: "%.1fs", titleDuration)).font(.caption.monospacedDigit()).frame(width: 42)
                }
                grid(TitlePreset.allCases.map { ($0.title, $0.icon) }) { index in
                    timeline.addTitle(TitlePreset.allCases[index], duration: titleDuration)
                }
                hint("Template Pop dan News memiliki animasi masuk. Pilih klip untuk mengubah teks di Inspector.")
            case .transitions:
                HStack {
                    Text("Durasi").font(.caption)
                    Slider(value: $duration, in: 0.25...3)
                    Text(String(format: "%.2fs", duration)).font(.caption.monospacedDigit()).frame(width: 44)
                }
                grid(TransitionKind.allCases.map { ($0.title, "rectangle.on.rectangle") }) { index in
                    timeline.applyTransition(TransitionKind.allCases[index], duration: duration)
                }
                hint("Dipasang di awal klip primary terpilih; kedua klip bertumpuk selama durasi transisi.")
            case .looks:
                grid(LookPreset.allCases.map { ($0.title, "camera.filters") }) { index in
                    timeline.applyLook(LookPreset.allCases[index])
                }
                hint("Mengganti pengaturan warna klip video terpilih (LUT tetap dipertahankan).")
            case .captions:
                VStack(spacing: 8) {
                    Picker("Bahasa", selection: $captionLocaleIdentifier) {
                        Text("Bahasa Indonesia").tag("id-ID")
                        if Locale.current.identifier != "id-ID" {
                            Text("Ikuti bahasa sistem").tag(Locale.current.identifier)
                        }
                    }
                    .controlSize(.small)
                    Button {
                        Task {
                            await timeline.generateCaptions(
                                for: timeline.selectedClipID,
                                locale: Locale(identifier: captionLocaleIdentifier))
                        }
                    } label: {
                        Label("Buat Auto Caption", systemImage: "waveform.badge.mic")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(timeline.selectedClipID == nil || timeline.isTranscribing)
                    .help("Buat subtitle memakai bahasa Indonesia atau bahasa sistem. Pilih caption di timeline untuk mengedit teksnya.")

                    HStack {
                        Button("Impor SRT…") { timeline.importSRT() }
                        Spacer()
                        Button("Ekspor SRT…") { timeline.exportSRT() }
                    }
                    .controlSize(.small)
                }
                hint("Caption berada di lane khusus. Pilih klip caption untuk mengubah teks, font, ukuran, warna, dan posisi di Inspector.")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func grid(_ items: [(String, String)], action: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                Button { action(i) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: items[i].1).font(.system(size: 18))
                        Text(items[i].0).font(.system(size: 11)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(templateHelp(items[i].0))
            }
        }
    }

    private func templateHelp(_ title: String) -> String {
        switch title {
        case "Social Hook", "Social Caption": "Tambahkan teks pop dengan animasi scale dan opacity."
        case "News Banner": "Tambahkan lower-third yang masuk dari kiri."
        case "End Card", "Cinematic": "Tambahkan title dengan fade in/out."
        case "Subtitle", "Subtitle Bar": "Tambahkan caption yang teksnya bisa diedit di Inspector."
        default: "Tambahkan template \(title) di posisi playhead."
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(FCP.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Editor judul / caption di Inspector.
struct TitleEditor: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip

    private var families: [String] {
        Array(Set(NSFontManager.shared.availableFontFamilies + [spec.fontFamily])).sorted()
    }

    private var spec: TitleSpec { clip.title ?? TitleSpec() }

    private func textBinding<T>(_ keyPath: WritableKeyPath<TitleSpec, T>) -> Binding<T> {
        Binding(get: { timeline.clip(clip.id)?.title?[keyPath: keyPath] ?? TitleSpec()[keyPath: keyPath] },
                set: { value in timeline.updateTitle(clip.id) { $0[keyPath: keyPath] = value } })
    }

    private func colorBinding(_ keyPath: WritableKeyPath<TitleSpec, [Double]>) -> Binding<Color> {
        Binding(
            get: {
                let c = (timeline.clip(clip.id)?.title?[keyPath: keyPath] ?? [1, 1, 1, 1]) + [1, 1, 1, 1]
                return Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                timeline.updateTitle(clip.id) {
                    $0[keyPath: keyPath] = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent)]
                }
            })
    }

    private func numberBinding(_ keyPath: WritableKeyPath<TitleSpec, Double>) -> Binding<Double> { textBinding(keyPath) }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { timeline.clip(clip.id)?.title?.fontSize ?? spec.fontSize },
            set: { value in timeline.updateTitle(clip.id) { $0.fontSize = min(max(value, 20), 300) } })
    }

    var body: some View {
        InspectorSection(title: spec.isCaption ? "Caption" : "Judul") {
            TextEditor(text: textBinding(\.text))
                .font(.system(size: 12))
                .frame(height: 70)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))

            HStack {
                Text("Font").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                Picker("", selection: textBinding(\.fontFamily)) {
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("Ukuran").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                Slider(value: fontSizeBinding, in: 20...300, step: 1)
                    .controlSize(.small)
                TextField("", value: fontSizeBinding, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 52)
                    .help("Ukuran font dalam piksel pada tinggi frame 1080")
            }
            InspectorSlider(label: "Spasi huruf", value: numberBinding(\.letterSpacing), range: 0...40) { String(format: "%.0f", $0) }
            HStack(spacing: 14) {
                Toggle("Tebal", isOn: textBinding(\.bold))
                Toggle("KAPITAL", isOn: textBinding(\.uppercase))
                Toggle("Bayangan", isOn: textBinding(\.shadow))
            }
            .controlSize(.small)
            .font(.system(size: 11))

            HStack {
                Text("Rata").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                Picker("", selection: textBinding(\.alignment)) {
                    Image(systemName: "text.alignleft").tag(0)
                    Image(systemName: "text.aligncenter").tag(1)
                    Image(systemName: "text.alignright").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            HStack {
                Text("Warna").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                ColorPicker("", selection: colorBinding(\.color)).labelsHidden()
                Spacer()
            }
        }

        InspectorSection(title: "Latar") {
            Toggle("Kotak latar", isOn: textBinding(\.backgroundEnabled)).controlSize(.small)
            if spec.backgroundEnabled {
                HStack {
                    Text("Warna").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                    ColorPicker("", selection: colorBinding(\.backgroundColor)).labelsHidden()
                    Spacer()
                }
            }
        }

        InspectorSection(title: "Posisi") {
            InspectorSlider(label: "Horizontal", value: numberBinding(\.positionX), range: 0...1) { String(format: "%.2f", $0) }
            InspectorSlider(label: "Vertikal", value: numberBinding(\.positionY), range: 0...1) { String(format: "%.2f", $0) }
        }

        TrackerSection(clip: clip)

        InspectorSection(title: "Animasi") {
            InspectorSlider(label: "Fade in", value: Binding(
                get: { timeline.clip(clip.id)?.fadeIn ?? 0 },
                set: { v in timeline.updateClip(clip.id) { $0.fadeIn = v } }), range: 0...3) { String(format: "%.1fs", $0) }
            InspectorSlider(label: "Fade out", value: Binding(
                get: { timeline.clip(clip.id)?.fadeOut ?? 0 },
                set: { v in timeline.updateClip(clip.id) { $0.fadeOut = v } }), range: 0...3) { String(format: "%.1fs", $0) }
            AnimatedSlider(clipID: clip.id, property: .opacity)
            AnimatedSlider(clipID: clip.id, property: .scale)
            AnimatedSlider(clipID: clip.id, property: .positionY)
            Text("Properti dengan berlian bisa dianimasikan dengan keyframe.")
                .font(.system(size: 9)).foregroundStyle(FCP.secondary)
        }
    }
}
