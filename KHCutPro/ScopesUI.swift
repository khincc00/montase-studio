import SwiftUI

/// Scope langsung dari frame di Viewer. Frame diambil lewat AVPlayerItemVideoOutput sekitar 10 kali per detik.
struct ScopesView: View {
    @Environment(TimelineModel.self) private var timeline
    @State private var mode: ScopeMode = .waveform
    @State private var data: ScopeData?

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $mode) {
                ForEach(ScopeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)

            ZStack {
                Rectangle().fill(Color.black)
                if let data { scope(data) } else {
                    Text("Tidak ada sinyal").font(.system(size: 10)).foregroundStyle(FCP.secondary)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .task {
            while !Task.isCancelled {
                if let buffer = timeline.currentFrameBuffer() { data = Scopes.compute(buffer) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @ViewBuilder
    private func scope(_ d: ScopeData) -> some View {
        switch mode {
        case .waveform:
            ZStack {
                if let image = Scopes.image(d.waveform, width: 256, height: 256, tint: (0.35, 1, 0.45)) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none)
                }
                graticule(levels: 5)
            }
        case .parade:
            ZStack {
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { channel in
                        let tint: (Double, Double, Double) = [(1, 0.3, 0.3), (0.3, 1, 0.3), (0.4, 0.5, 1)][channel]
                        if let image = Scopes.image(d.parade[channel], width: ScopeData.paradeColumns, height: 256, tint: tint) {
                            Image(decorative: image, scale: 1).resizable().interpolation(.none)
                        } else { Color.clear }
                    }
                }
                graticule(levels: 5)
            }
        case .vectorscope:
            ZStack {
                if let image = Scopes.image(d.vectorscope, width: 256, height: 256, tint: (0.5, 1, 0.8)) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                }
                Canvas { context, size in
                    let side = min(size.width, size.height)
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    for f in [0.25, 0.5, 0.75, 1.0] {
                        let r = side / 2 * f
                        context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                       with: .color(.white.opacity(0.18)), lineWidth: 1)
                    }
                    var cross = Path()
                    cross.move(to: CGPoint(x: c.x - side / 2, y: c.y)); cross.addLine(to: CGPoint(x: c.x + side / 2, y: c.y))
                    cross.move(to: CGPoint(x: c.x, y: c.y - side / 2)); cross.addLine(to: CGPoint(x: c.x, y: c.y + side / 2))
                    context.stroke(cross, with: .color(.white.opacity(0.18)), lineWidth: 1)
                    // Garis kulit (skin tone) ≈ 123° pada sumbu Cb/Cr
                    var skin = Path()
                    let a = 123.0 * .pi / 180
                    skin.move(to: c); skin.addLine(to: CGPoint(x: c.x + cos(a) * side / 2, y: c.y - sin(a) * side / 2))
                    context.stroke(skin, with: .color(.orange.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        case .histogram:
            Canvas { context, size in
                let colors: [Color] = [.red, .green, .blue, .white]
                for channel in 0..<4 {
                    let bins = d.histogram[channel]
                    let peak = Double(bins.max() ?? 1)
                    guard peak > 0 else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (i, count) in bins.enumerated() {
                        let x = CGFloat(i) / 255 * size.width
                        let y = size.height - CGFloat((Double(count) / peak).squareRoot()) * size.height
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    context.fill(path, with: .color(colors[channel].opacity(channel == 3 ? 0.18 : 0.4)))
                    if channel == 3 { context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1) }
                }
            }
        }
    }

    private func graticule(levels: Int) -> some View {
        Canvas { context, size in
            var path = Path()
            for i in 0..<levels {
                let y = size.height * CGFloat(i) / CGFloat(levels - 1)
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Roda warna dengan puck yang bisa diseret. Klik dua kali untuk mereset puck.
struct ColorWheelView: View {
    let title: String
    @Binding var wheel: ColorWheel
    let onBegin: () -> Void
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(FCP.secondary)
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height), r = d / 2
                ZStack {
                    Circle().fill(AngularGradient(colors: [.red, Color(red: 1, green: 0, blue: 1), .blue, .cyan, .green, .yellow, .red], center: .center))
                        .opacity(0.8)
                    Circle().fill(RadialGradient(colors: [Color(white: 0.45), .clear], center: .center, startRadius: 0, endRadius: r))
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                        .position(x: r + wheel.x * r, y: r - wheel.y * r)
                }
                .frame(width: d, height: d)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !dragging { onBegin(); dragging = true }
                            var x = Double((value.location.x - r) / r), y = -Double((value.location.y - r) / r)
                            let m = hypot(x, y)
                            if m > 1 { x /= m; y /= m }
                            wheel.x = x
                            wheel.y = y
                        }
                        .onEnded { _ in dragging = false }
                )
                .onTapGesture(count: 2) { onBegin(); wheel = ColorWheel() }
            }
            .aspectRatio(1, contentMode: .fit)

            Slider(value: $wheel.master, in: -1...1) { editing in if editing { onBegin() } }
                .controlSize(.mini)
        }
    }
}

/// Daftar node grading klip: pilih, tambah, bypass, hapus, urutkan, salin/tempel grade.
struct NodeStrip: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip

    var body: some View {
        InspectorSection(title: "Nodes") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(clip.nodes.enumerated()), id: \.element.id) { index, node in
                        Button { timeline.selectNode(index, in: clip.id) } label: {
                            HStack(spacing: 4) {
                                Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .monospaced))
                                Text(node.name).font(.system(size: 10)).lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(index == clip.activeNode ? FCP.selection.opacity(0.9) : Color.white.opacity(0.1))
                            .foregroundStyle(index == clip.activeNode ? Color.black : (node.enabled ? Color.white : Color.white.opacity(0.35)))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay { if !node.enabled { Rectangle().fill(Color.white.opacity(0.5)).frame(height: 1) } }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(node.enabled ? "Bypass Node" : "Enable Node") { timeline.toggleNode(index, in: clip.id) }
                        }
                        if index < clip.nodes.count - 1 {
                            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(FCP.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Button { timeline.addNode(to: clip.id) } label: { Image(systemName: "plus") }
                    .help("Tambah node setelah node terpilih")
                Button { timeline.deleteActiveNode(in: clip.id) } label: { Image(systemName: "minus") }
                    .disabled(clip.nodes.count < 2)
                    .help("Hapus node terpilih")
                Button { timeline.toggleNode(clip.activeNode, in: clip.id) } label: { Image(systemName: "eye.slash") }
                    .help("Bypass / aktifkan node terpilih")
                Button { timeline.moveActiveNode(in: clip.id, by: -1) } label: { Image(systemName: "arrow.left") }
                    .disabled(clip.activeNode == 0)
                Button { timeline.moveActiveNode(in: clip.id, by: 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(clip.activeNode >= clip.nodes.count - 1)
                Spacer()
                Button("Copy") { timeline.copyGrade(from: clip.id) }.help("Salin semua node klip ini")
                Button("Paste") { timeline.pasteGrade() }.disabled(timeline.gradeClipboard == nil).help("Tempel ke klip video atau adjustment layer terpilih")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Text("Node dijalankan berurutan dari kiri ke kanan. Slider di bawah mengedit node terpilih.")
                .font(.system(size: 9)).foregroundStyle(FCP.secondary)
        }
    }
}
