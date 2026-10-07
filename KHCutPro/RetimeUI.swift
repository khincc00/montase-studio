import SwiftUI

/// Inspector kecepatan klip: preset, kecepatan konstan, dan editor titik speed ramp.
struct RetimeSection: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip

    private var retime: Retime { clip.retime ?? Retime() }

    var body: some View {
        InspectorSection(title: "Speed") {
            HStack {
                Text("Preset").font(.system(size: 11)).foregroundStyle(FCP.secondary).frame(width: 66, alignment: .leading)
                Menu("Pilih…") {
                    ForEach(Retime.Preset.allCases) { preset in
                        Button(preset.title) { timeline.applyRetimePreset(clip.id, preset) }
                    }
                }
                .controlSize(.small)
                Spacer()
            }
            if retime.isRamp {
                Text("Speed ramp aktif · \(retime.keys.count) titik")
                    .font(.system(size: 10)).foregroundStyle(FCP.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(retime.keys.enumerated()), id: \.offset) { index, key in
                    HStack(spacing: 6) {
                        Text(String(format: "%.2fs", key.time))
                            .font(.system(size: 10, design: .monospaced)).frame(width: 46, alignment: .leading)
                        Slider(value: Binding(get: { key.speed },
                                              set: { timeline.setSpeedKey(clip.id, index: index, speed: $0) }),
                               in: 0.1...8) { editing in if editing { timeline.checkpoint() } }
                            .controlSize(.small)
                        Text(String(format: "%.2f×", key.speed))
                            .font(.system(size: 10, design: .monospaced)).frame(width: 44, alignment: .trailing)
                        Button { timeline.removeSpeedKey(clip.id, index: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Hapus titik kecepatan")
                    }
                }
            } else {
                InspectorSlider(label: "Kecepatan",
                                value: Binding(get: { retime.speed },
                                               set: { timeline.setSpeed(clip.id, $0) }),
                                range: 0.1...8) { String(format: "%.2f×", $0) }
            }
            HStack {
                Button("Tambah Titik Ramp") { timeline.addSpeedKey(clip.id) }
                    .help("Tambah titik kecepatan di posisi playhead")
                Button("Reset") { timeline.setRetime(clip.id, nil) }
                    .disabled(!clip.isRetimed)
                Spacer()
                Text(String(format: "Durasi %.2fs", clip.duration))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(FCP.secondary)
            }
            .controlSize(.small)
            Text("Mengubah kecepatan memanjang/memendekkan klip; potongan media yang dipakai tetap. Ramp mengubah kecepatan secara halus antar titik. Audio mengikuti kecepatan dengan pitch dipertahankan.")
                .font(.system(size: 9)).foregroundStyle(FCP.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pemilih frame rate project (24 / 30 / 60 fps).
struct FrameRateMenu: View {
    @Environment(TimelineModel.self) private var timeline

    var body: some View {
        Menu {
            ForEach(supportedFrameRates, id: \.self) { fps in
                Button {
                    timeline.setFrameRate(fps)
                } label: {
                    if timeline.frameRate == fps { Label("\(Int(fps)) fps", systemImage: "checkmark") } else { Text("\(Int(fps)) fps") }
                }
            }
        } label: {
            Text("\(Int(timeline.frameRate)) fps")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(FCP.secondary)
        .help("Frame rate project (24 / 30 / 60 fps)")
    }
}
