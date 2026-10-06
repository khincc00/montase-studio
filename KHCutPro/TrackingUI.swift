import SwiftUI

/// Stabilisasi klip video: analisis getaran → keyframe posisi dan zoom pengisi tepi.
struct StabilizerSection: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip
    @State private var smoothing = 1.0

    var body: some View {
        InspectorSection(title: "Stabilization") {
            InspectorSlider(label: "Kehalusan", value: $smoothing, range: 0.25...3) { String(format: "%.1fs", $0) }
            HStack {
                Button("Stabilkan Klip") {
                    let id = clip.id, value = smoothing
                    Task { await timeline.stabilize(id, smoothing: value) }
                }
                .disabled(timeline.isAnalyzing)
                Button("Hapus") {
                    timeline.resetProperties(clip.id, [.positionX, .positionY, .scale])
                }
                .help("Hapus keyframe posisi dan scale hasil stabilisasi")
                if timeline.isAnalyzing { ProgressView().controlSize(.small); Text(timeline.analysisStatus).font(.caption) }
            }
            .controlSize(.small)
            Text("Makin besar nilai, makin halus (gerak panning lambat tetap dipertahankan). Klip diperbesar sedikit untuk menutup tepi.")
                .font(.system(size: 9)).foregroundStyle(FCP.secondary)
        }
    }
}

/// Klip (judul / connected) mengikuti objek di video di bawahnya.
struct TrackerSection: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip

    var body: some View {
        InspectorSection(title: "Tracking") {
            Toggle("Tandai titik di Viewer", isOn: Binding(get: { timeline.isTrackerPlacing }, set: { timeline.isTrackerPlacing = $0 }))
                .controlSize(.small)
            HStack {
                Button("Lacak Objek") {
                    let id = clip.id
                    timeline.isTrackerPlacing = false
                    Task { await timeline.trackPoint(for: id) }
                }
                .disabled(timeline.isAnalyzing)
                Button("Hapus Pelacakan") { timeline.resetProperties(clip.id, [.positionX, .positionY]) }
                if timeline.isAnalyzing { ProgressView().controlSize(.small); Text(timeline.analysisStatus).font(.caption) }
            }
            .controlSize(.small)
            Text("1) Geser playhead ke awal pelacakan. 2) Nyalakan “Tandai titik” dan seret tanda silang ke objek. 3) Lacak Objek: posisi klip ini di-keyframe mengikuti objek sampai klip berakhir.")
                .font(.system(size: 9)).foregroundStyle(FCP.secondary)
        }
    }
}

/// Tanda silang di Viewer untuk memilih titik yang akan dilacak.
struct TrackerCrosshair: View {
    @Environment(TimelineModel.self) private var timeline

    var body: some View {
        GeometryReader { geo in
            let render = timeline.renderSize
            let k = min(geo.size.width / render.width, geo.size.height / render.height)
            let frame = CGRect(x: (geo.size.width - render.width * k) / 2, y: (geo.size.height - render.height * k) / 2,
                               width: render.width * k, height: render.height * k)
            let p = CGPoint(x: frame.minX + timeline.trackerPoint.x * frame.width, y: frame.minY + timeline.trackerPoint.y * frame.height)
            ZStack {
                Circle().stroke(Color.cyan, lineWidth: 1.5).frame(width: 30, height: 30)
                Path { path in
                    path.move(to: CGPoint(x: 15, y: 0)); path.addLine(to: CGPoint(x: 15, y: 30))
                    path.move(to: CGPoint(x: 0, y: 15)); path.addLine(to: CGPoint(x: 30, y: 15))
                }
                .stroke(Color.cyan, lineWidth: 1)
                .frame(width: 30, height: 30)
            }
            .position(p)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trackerSpace"))
                    .onChanged { value in
                        timeline.trackerPoint = CGPoint(x: min(max((value.location.x - frame.minX) / frame.width, 0), 1),
                                                        y: min(max((value.location.y - frame.minY) / frame.height, 0), 1))
                    }
            )
        }
        .coordinateSpace(name: "trackerSpace")
    }
}
