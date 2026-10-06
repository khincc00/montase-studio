import SwiftUI

/// Slider properti yang bisa dianimasikan: tombol berlian menambah/menghapus keyframe di playhead.
struct AnimatedSlider: View {
    @Environment(TimelineModel.self) private var timeline
    let clipID: UUID
    let property: AnimProperty

    var body: some View {
        let animated = timeline.clip(clipID)?.isAnimated(property) ?? false
        let value = timeline.currentValue(clipID, property)
        HStack(spacing: 6) {
            Text(property.title)
                .font(.system(size: 11))
                .foregroundStyle(FCP.secondary)
                .frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { timeline.setValue(clipID, property, $0) }), in: property.range) { editing in
                if editing { timeline.checkpoint() }
            }
            .controlSize(.small)
            Text(property.format(value))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 54, alignment: .trailing)
            Button { timeline.toggleKeyframe(clipID, property) } label: {
                Image(systemName: timeline.hasKeyframe(clipID, property) ? "diamond.fill" : "diamond")
                    .font(.system(size: 10))
                    .foregroundStyle(animated ? FCP.selection : FCP.secondary)
            }
            .buttonStyle(.plain)
            .help("Tambah / hapus keyframe di posisi playhead")
        }
        .contextMenu {
            Button("Remove All Keyframes") { timeline.clearKeyframes(clipID, property) }
                .disabled(!animated)
        }
    }
}

/// Pemilih kurva untuk segmen keyframe di bawah playhead, lengkap dengan editor Bezier.
struct KeyframeCurveSection: View {
    @Environment(TimelineModel.self) private var timeline
    let clip: TimelineClip
    @State private var selected: AnimProperty?

    private var animated: [AnimProperty] {
        AnimProperty.allCases.filter { clip.isAnimated($0) }
    }

    var body: some View {
        if !animated.isEmpty {
            let property = selected.flatMap { animated.contains($0) ? $0 : nil } ?? animated[0]
            InspectorSection(title: "Keyframe Curve") {
                Picker("", selection: Binding(get: { property }, set: { selected = $0 })) {
                    ForEach(animated, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)

                if let easing = timeline.easing(clip.id, property) {
                    HStack(spacing: 4) {
                        ForEach([Easing.linear, .easeIn, .easeOut, .easeInOut, .hold], id: \.title) { preset in
                            Button(preset.title) { timeline.checkpoint(); timeline.setEasing(clip.id, property, preset) }
                                .controlSize(.mini)
                                .buttonStyle(.bordered)
                                .tint(easing == preset ? FCP.selection : nil)
                        }
                    }
                    BezierEditor(easing: easing) { timeline.setEasing(clip.id, property, $0) }
                        .frame(height: 120)
                    Text("Kurva berlaku dari keyframe di kiri playhead menuju keyframe berikutnya.")
                        .font(.system(size: 9))
                        .foregroundStyle(FCP.secondary)
                } else {
                    Text("Geser playhead ke dalam klip untuk mengatur kurva.")
                        .font(.system(size: 10))
                        .foregroundStyle(FCP.secondary)
                }
            }
        }
    }
}

/// Editor kurva Bezier kubik dengan dua titik kendali yang bisa diseret (overshoot diperbolehkan pada sumbu y).
struct BezierEditor: View {
    @Environment(TimelineModel.self) private var timeline
    let easing: Easing
    let onChange: (Easing) -> Void
    @State private var dragging = false

    private let inset: CGFloat = 12
    private let yMin = -0.5, yMax = 1.5

    var body: some View {
        let points = easing.controlPoints
        GeometryReader { geo in
            let w = geo.size.width - inset * 2, h = geo.size.height - inset * 2
            let map = { (x: Double, y: Double) in point(x, y, w: w, h: h) }
            ZStack {
                Rectangle().fill(FCP.background)
                Canvas { context, _ in
                    var grid = Path()
                    for i in 0...4 {
                        let a = map(Double(i) / 4, yMin), b = map(Double(i) / 4, yMax)
                        grid.move(to: a); grid.addLine(to: b)
                    }
                    for y in [0.0, 1.0] {
                        grid.move(to: map(0, y)); grid.addLine(to: map(1, y))
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 1)

                    var handles = Path()
                    handles.move(to: map(0, 0)); handles.addLine(to: map(points.0, points.1))
                    handles.move(to: map(1, 1)); handles.addLine(to: map(points.2, points.3))
                    context.stroke(handles, with: .color(.white.opacity(0.35)), lineWidth: 1)

                    var curve = Path()
                    curve.move(to: map(0, 0))
                    curve.addCurve(to: map(1, 1), control1: map(points.0, points.1), control2: map(points.2, points.3))
                    context.stroke(curve, with: .color(FCP.selection), lineWidth: 2)
                }
                handle(at: map(points.0, points.1), index: 0, w: w, h: h)
                handle(at: map(points.2, points.3), index: 1, w: w, h: h)
            }
            .coordinateSpace(name: "bezier")
        }
    }

    private func point(_ x: Double, _ y: Double, w: CGFloat, h: CGFloat) -> CGPoint {
        CGPoint(x: inset + x * w, y: inset + (1 - (y - yMin) / (yMax - yMin)) * h)
    }

    private func handle(at point: CGPoint, index: Int, w: CGFloat, h: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 11, height: 11)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("bezier"))
                    .onChanged { value in
                        if !dragging { timeline.checkpoint(); dragging = true }
                        let x = min(max(Double((value.location.x - inset) / w), 0), 1)
                        let y = min(max((1 - Double((value.location.y - inset) / h)) * (yMax - yMin) + yMin, yMin), yMax)
                        var p = easing.controlPoints
                        if index == 0 { p.0 = x; p.1 = y } else { p.2 = x; p.3 = y }
                        onChange(.bezier(p.0, p.1, p.2, p.3))
                    }
                    .onEnded { _ in dragging = false }
            )
    }
}

/// Kontrol transform langsung di Viewer: seret isi untuk posisi, sudut untuk scale, titik atas untuk rotasi.
struct ViewerOverlay: View {
    @Environment(TimelineModel.self) private var timeline

    private struct Start { var px, py, scale, rotation: Double; var cornerDistance: CGFloat }
    @State private var start: Start?
    @State private var titleDragStart: (x: Double, y: Double)?
    @State private var titleFontStart: Double?

    var body: some View {
        GeometryReader { geo in
            if let clip = timeline.selectedClip,
               timeline.playhead >= clip.startTime - 0.001, timeline.playhead <= clip.endTime + 0.001 {
                if clip.isTitle {
                    titleContent(clip: clip, size: geo.size)
                } else if (clip.asset.fileType == .video || clip.asset.fileType == .image),
                          !clip.isContainer, clip.asset.naturalSize != .zero {
                    content(clip: clip, size: geo.size)
                }
            }
        }
        .coordinateSpace(name: "viewer")
    }

    private func content(clip: TimelineClip, size: CGSize) -> some View {
        let render = timeline.renderSize
        let k = min(size.width / render.width, size.height / render.height)
        let origin = CGPoint(x: (size.width - render.width * k) / 2, y: (size.height - render.height * k) / 2)
        let nat = clip.asset.naturalSize
        let fit = min(render.width / nat.width, render.height / nat.height)

        let scale = timeline.currentValue(clip.id, .scale)
        let rotation = timeline.currentValue(clip.id, .rotation)
        let px = timeline.currentValue(clip.id, .positionX)
        let py = timeline.currentValue(clip.id, .positionY)
        let w = nat.width * fit * scale * k, h = nat.height * fit * scale * k
        let center = CGPoint(x: origin.x + (render.width / 2 + px) * k, y: origin.y + (render.height / 2 - py) * k)
        let id = clip.id

        func begin() {
            if start == nil {
                timeline.checkpoint()
                start = Start(px: px, py: py, scale: scale, rotation: rotation, cornerDistance: hypot(w / 2, h / 2))
            }
        }

        return ZStack {
            Rectangle()
                .stroke(FCP.selection, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .help("Drag to move the selected video; drag corner handles to scale.")
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { value in
                            begin()
                            guard let s = start else { return }
                            timeline.setValue(id, .positionX, s.px + Double(value.translation.width / k))
                            timeline.setValue(id, .positionY, s.py - Double(value.translation.height / k))
                        }
                        .onEnded { _ in start = nil }
                )

            ForEach(0..<4, id: \.self) { corner in
                let sx: CGFloat = corner % 2 == 0 ? -1 : 1, sy: CGFloat = corner < 2 ? -1 : 1
                Rectangle()
                    .fill(FCP.selection)
                    .frame(width: 9, height: 9)
                    .position(x: w / 2 + sx * w / 2, y: h / 2 + sy * h / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("viewer"))
                            .onChanged { value in
                                begin()
                                guard let s = start else { return }
                                let d = hypot(value.location.x - center.x, value.location.y - center.y)
                                timeline.setValue(id, .scale, s.scale * Double(d / max(s.cornerDistance, 1)))
                            }
                            .onEnded { _ in start = nil }
                    )
            }

            Circle()
                .fill(FCP.selection)
                .frame(width: 10, height: 10)
                .position(x: w / 2, y: -16)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("viewer"))
                        .onChanged { value in
                            begin()
                            let dx = value.location.x - center.x, dy = value.location.y - center.y
                            // sudut searah jarum jam dari atas; rotasi positif = berlawanan arah jarum jam
                            timeline.setValue(id, .rotation, -Double(atan2(dx, -dy)) * 180 / .pi)
                        }
                        .onEnded { _ in start = nil }
                )
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(-rotation))
        .position(center)
    }

    private func titleContent(clip: TimelineClip, size: CGSize) -> some View {
        guard let spec = clip.title else { return AnyView(EmptyView()) }
        let render = timeline.renderSize
        let k = min(size.width / render.width, size.height / render.height)
        let origin = CGPoint(x: (size.width - render.width * k) / 2, y: (size.height - render.height * k) / 2)
        let center = CGPoint(x: origin.x + spec.positionX * render.width * k,
                             y: origin.y + spec.positionY * render.height * k)
        let fontSize = spec.fontSize * render.height / 1080 * k
        let id = clip.id
        let text = spec.uppercase ? spec.text.uppercased() : spec.text

        return AnyView(
            Text(text.isEmpty ? " " : text)
                .font(.custom(spec.fontFamily, size: fontSize, relativeTo: .largeTitle))
                .fontWeight(spec.bold ? .bold : .regular)
                .multilineTextAlignment(spec.alignment == 0 ? .leading : (spec.alignment == 2 ? .trailing : .center))
                .lineLimit(nil)
                .fixedSize()
                .padding(10)
                .background(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(FCP.selection, lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(FCP.selection)
                        .frame(width: 10, height: 10)
                        .offset(x: 5, y: -5)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if titleFontStart == nil {
                                        timeline.checkpoint()
                                        titleFontStart = spec.fontSize
                                    }
                                    guard let initial = titleFontStart else { return }
                                    let factor = max(0.4, min(3, 1 + (value.translation.width - value.translation.height) / 240))
                                    timeline.updateTitle(id) { $0.fontSize = min(300, max(20, initial * factor)) }
                                }
                                .onEnded { _ in titleFontStart = nil }
                        )
                        .help("Drag to resize the selected title.")
                }
                .contentShape(Rectangle())
                .position(center)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { value in
                            if titleDragStart == nil {
                                timeline.checkpoint()
                                titleDragStart = (spec.positionX, spec.positionY)
                            }
                            guard let initial = titleDragStart else { return }
                            timeline.updateTitle(id) {
                                $0.positionX = min(1, max(0, initial.x + Double(value.translation.width / (render.width * k))))
                                $0.positionY = min(1, max(0, initial.y + Double(value.translation.height / (render.height * k))))
                            }
                        }
                        .onEnded { _ in titleDragStart = nil }
                )
                .help("Drag to position the selected title directly in the viewer.")
        )
    }
}
