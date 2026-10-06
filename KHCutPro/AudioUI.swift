import SwiftUI

/// Waveform dari puncak amplitudo sumber, digambar sesuai bagian media yang dipakai klip.
struct WaveformView: View {
    let assetID: UUID
    let offset: Double
    let duration: Double
    let zoom: Double
    let color: Color

    var body: some View {
        let peaks = WaveformCache.shared.peaks[assetID] ?? []
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            var path = Path()
            let mid = size.height / 2
            var x: CGFloat = 0
            while x < size.width {
                let t = offset + Double(x) / zoom
                let i = Int(t / WaveformCache.hopSeconds)
                // puncak terbesar di rentang piksel ini agar transient tidak hilang saat zoom keluar
                let span = max(1, Int(2 / zoom / WaveformCache.hopSeconds))
                var peak: Float = 0
                for j in i..<(i + span) where j >= 0 && j < peaks.count { peak = max(peak, peaks[j]) }
                let h = max(1, CGFloat(min(1, peak * 1.4)) * mid)
                path.move(to: CGPoint(x: x, y: mid - h)); path.addLine(to: CGPoint(x: x, y: mid + h))
                x += 2
            }
            context.stroke(path, with: .color(color), lineWidth: 1.2)
        }
        .frame(width: max(1, duration * zoom))
        .allowsHitTesting(false)
    }
}

/// Meter level master di samping Viewer (perkiraan dari waveform sumber, penguatan klip, dan mixer peran).
struct AudioMeter: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(Transport.self) private var transport
    @State private var hold: Float = 0

    var body: some View {
        let level = transport.usesSource ? 0 : timeline.meterLevel(at: timeline.playhead)
        let db = level > 0.0005 ? 20 * log10(level) : -80
        let fraction = CGFloat(min(1, max(0, (db + 60) / 60)))
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color.black)
                    Rectangle()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                        .frame(height: geo.size.height * fraction)
                    ForEach([-6.0, -12.0, -24.0, -48.0], id: \.self) { mark in
                        Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1)
                            .offset(y: -geo.size.height * CGFloat((mark + 60) / 60) )
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            Text(db > -79 ? String(format: "%.0f", db) : "−∞")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(db > -3 ? .red : FCP.secondary)
        }
        .frame(width: 20)
        .padding(.vertical, 4)
        .background(FCP.panel)
        .help("Level audio (dBFS, perkiraan)")
    }
}

/// Peran klip, mixer per peran, dan otomatisasi audio.
struct RoleMixerSection: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip

    var body: some View {
        InspectorSection(title: "Peran (Roles)") {
            HStack {
                Text("Peran klip").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                Picker("", selection: Binding(get: { timeline.clip(clip.id)?.role ?? .dialogue }, set: { timeline.setRole(clip.id, $0) })) {
                    ForEach(AudioRole.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            ForEach(AudioRole.allCases, id: \.self) { role in
                let mix = timeline.roleMix[role] ?? RoleMix()
                HStack(spacing: 6) {
                    Text(role.title).font(.system(size: 11)).frame(width: 52, alignment: .leading)
                    Slider(value: Binding(get: { mix.volumeDB }, set: { v in timeline.setRoleMix(role) { $0.volumeDB = v } }), in: -60...12)
                        .controlSize(.small)
                    Text(String(format: "%+.0f", mix.volumeDB)).font(.system(size: 10, design: .monospaced)).frame(width: 28, alignment: .trailing)
                    toggle("M", on: mix.muted, tint: .orange) { timeline.setRoleMix(role) { $0.muted.toggle() } }
                    toggle("S", on: mix.solo, tint: .yellow) { timeline.setRoleMix(role) { $0.solo.toggle() } }
                }
            }
            Text("Fader, Mute (M), dan Solo (S) berlaku untuk semua klip dengan peran itu. Klip audio-saja otomatis masuk lane perannya.")
                .font(.system(size: 9)).foregroundStyle(FCP.secondary)
        }

        InspectorSection(title: "Otomatisasi") {
            HStack {
                Button("Auto-Duck Musik") { Task { await timeline.autoDuck() } }
                    .help("Musik (peran Musik) mengecil otomatis saat ada Dialog")
                Button("Auto-Sync Audio") { Task { await timeline.autoSyncAudioToVideo() } }
                    .help("Pilih satu klip video dan satu klip audio; audio disejajarkan ke suara video")
                if timeline.isAnalyzing { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .disabled(timeline.isAnalyzing)
            HStack {
                Button("Tandai Beat") { let id = clip.id; Task { await timeline.markBeats(of: id) } }
                    .help("Deteksi tempo dan tandai tiap beat musik klip ini di timeline")
                Button("Potong ke Beat") { timeline.cutToBeats() }
                    .help("Pilih beberapa klip video, lalu potong supaya tiap sambungan jatuh di beat")
                if let bpm = timeline.detectedBPM { Text(String(format: "%.1f BPM", bpm)).font(.caption).foregroundStyle(FCP.secondary) }
            }
            .controlSize(.small)
            .disabled(timeline.isAnalyzing)
        }
    }

    private func toggle(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(width: 20, height: 18)
                .background(on ? tint : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

/// Efek audio per klip: high-pass, EQ, reduksi derau (gate), dan compressor.
struct AudioFXSection: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip

    private func fx<T>(_ keyPath: WritableKeyPath<AudioFX, T>) -> Binding<T> {
        Binding(get: { timeline.clip(clip.id)?.fx[keyPath: keyPath] ?? AudioFX()[keyPath: keyPath] },
                set: { value in timeline.updateClip(clip.id) { $0.fx[keyPath: keyPath] = value } })
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<AudioFX, Double>, _ range: ClosedRange<Double>,
                        _ format: @escaping (Double) -> String) -> some View {
        InspectorSlider(label: label, value: fx(keyPath), range: range, format: format)
    }

    var body: some View {
        InspectorSection(title: "Efek Audio") {
            Toggle("Aktifkan efek", isOn: Binding(
                get: { clip.fx.enabled },
                set: { on in timeline.checkpoint(); timeline.updateClip(clip.id) { $0.fx.enabled = on } }))
                .controlSize(.small)
            if clip.fx.enabled {
                slider("High-pass", \.highPassHz, 0...400) { $0 < 1 ? "Off" : "\(Int($0)) Hz" }
                slider("EQ Low", \.eqLowDB, -12...12) { String(format: "%+.1f dB", $0) }
                slider("EQ Mid", \.eqMidDB, -12...12) { String(format: "%+.1f dB", $0) }
                slider("EQ High", \.eqHighDB, -12...12) { String(format: "%+.1f dB", $0) }

                Toggle("Reduksi derau (gate)", isOn: fx(\.gate)).controlSize(.small)
                if clip.fx.gate {
                    slider("Ambang", \.gateThresholdDB, -70...(-20)) { String(format: "%.0f dB", $0) }
                    slider("Peredaman", \.gateReductionDB, -60...(-6)) { String(format: "%.0f dB", $0) }
                }

                Toggle("Compressor", isOn: fx(\.compressor)).controlSize(.small)
                if clip.fx.compressor {
                    slider("Ambang", \.thresholdDB, -50...0) { String(format: "%.0f dB", $0) }
                    slider("Rasio", \.ratio, 1...12) { String(format: "%.1f:1", $0) }
                    slider("Attack", \.attackMs, 1...100) { String(format: "%.0f ms", $0) }
                    slider("Release", \.releaseMs, 20...800) { String(format: "%.0f ms", $0) }
                    slider("Makeup", \.makeupDB, 0...18) { String(format: "%+.1f dB", $0) }
                }
                Text("Reduksi derau memakai gate/expander dan high-pass, bukan model AI; Voice Isolation seperti di FCP belum tersedia.")
                    .font(.system(size: 9)).foregroundStyle(FCP.secondary)
            }
        }
    }
}
