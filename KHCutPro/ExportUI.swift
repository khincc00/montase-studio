import SwiftUI

/// Dialog export: pilih satu atau beberapa preset (batch), rentang, lalu folder tujuan.
struct ExportSheet: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<ExportPreset> = [.h264Master]
    @State private var name = "KHCutPro Project"
    @State private var useRange = true

    private var hasRange: Bool { timeline.markIn != nil || timeline.markOut != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Nama file").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preset (pilih beberapa untuk batch export)").font(.caption).foregroundStyle(.secondary)
                ForEach(ExportPreset.allCases) { preset in
                    Toggle(isOn: Binding(
                        get: { selected.contains(preset) },
                        set: { on in if on { selected.insert(preset) } else { selected.remove(preset) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.title)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if hasRange {
                Toggle("Hanya rentang In/Out (\(timecodeString(timeline.markIn ?? 0)) – \(timecodeString(timeline.markOut ?? timeline.totalDuration)))",
                       isOn: $useRange)
            }

            if timeline.isExporting {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: timeline.exportProgress)
                    Text(timeline.exportStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Tutup") { dismiss() }
                Button("Export…") {
                    let range: ClosedRange<Double>? = hasRange && useRange
                        ? (timeline.markIn ?? 0)...(timeline.markOut ?? timeline.totalDuration) : nil
                    timeline.runExport(presets: ExportPreset.allCases.filter { selected.contains($0) }, baseName: name, range: range)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || timeline.isExporting || name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
