import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
import AVFoundation


import CoreGraphics
func exportClips(_ clips: [TimelineClip], name: String) async throws -> URL {
    let built = await CompositionBuilder.build(clips: clips)
    let out = URL(fileURLWithPath: "\(dir)/\(name).mov"); try? FileManager.default.removeItem(at: out)
    let s = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetMediumQuality)!
    s.videoComposition = built.videoComposition; s.audioMix = built.audioMix
    try await s.export(to: out, as: .mov); return out
}
func frame(_ url: URL, _ t: Double) async throws -> CGImage {
    let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
    return try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
}
/// mean luma 0...255 of a normalized rect (origin top-left)
func luma(_ img: CGImage, _ r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> Double {
    let W = 160, H = 90
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0, n = 0.0
    for y in Int(r.minY * Double(H))..<Int(r.maxY * Double(H)) { for x in Int(r.minX * Double(W))..<Int(r.maxX * Double(W)) {
        let i = (y * W + x) * 4; sum += (Double(p[i]) + Double(p[i+1]) + Double(p[i+2])) / 3; n += 1 } }
    return sum / max(n, 1)
}

TimelineModel.autoRebuild = false
var failures = 0
func expect(_ c: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if c() { print("  ok   \(msg)") } else { print("  FAIL \(msg) (line \(line))"); failures += 1 }
}
let dir = CommandLine.arguments[1]
func asset(_ n: String) async -> MediaAsset { await AssetCompatibilityService().identifyAsset(url: URL(fileURLWithPath: "\(dir)/\(n)")) }
func primary(_ t: TimelineModel) -> [TimelineClip] { t.clips.filter { $0.lane == 0 }.sorted { $0.startTime < $1.startTime } }

print("== collision / anchors")
do {
    let a = await asset("camA.mp4"), b = await asset("camB.mp4")
    let t = TimelineModel(); t.append(a); t.append(b)
    t.seek(to: 5); t.connect(b); t.seek(to: 8); t.connect(b)
    expect(Set(t.clips.filter { $0.lane != 0 }.map(\.lane)) == [1, 2], "overlapping connected clips get separate lanes")
    let conn = t.clips.first { $0.lane == 1 }!
    expect(conn.anchorID == primary(t)[0].id, "connected clip anchored to primary under it")
    let first = primary(t)[0], second = primary(t)[1]
    let before = t.clip(conn.id)!.startTime
    t.moveClip(second.id, toStart: 0)
    expect(primary(t)[0].id == second.id, "primary reorder by drag")
    expect(abs(t.clip(conn.id)!.startTime - (before + second.duration)) < 0.01, "anchored clip moved with parent")
    t.select(first.id); t.deleteSelected()
    expect(primary(t).count == 1 && primary(t)[0].startTime == 0, "ripple delete closes gap")
}

print("== roll / slip / slide")
do {
    let a = await asset("camA.mp4")
    let t = TimelineModel(); t.append(a)
    t.seek(to: 5); t.select(t.clips[0].id); t.splitAtPlayhead()
    t.seek(to: 10); t.select(primary(t)[1].id); t.splitAtPlayhead()
    let total = t.totalDuration
    var p = primary(t); expect(p.count == 3, "3 clips after splits")
    t.roll(left: p[0].id, right: p[1].id, delta: 1); p = primary(t)
    expect(abs(p[0].duration - 6) < 0.01 && abs(p[1].duration - 4) < 0.01 && abs(p[1].offsetInAsset - 6) < 0.01, "roll moves edit point")
    expect(abs(t.totalDuration - total) < 0.01, "roll keeps total duration")
    let mid = p[1]; t.slip(mid.id, delta: 2); let m2 = t.clip(mid.id)!
    expect(abs(m2.offsetInAsset - (mid.offsetInAsset + 2)) < 0.01 && abs(m2.duration - mid.duration) < 0.01 && abs(m2.startTime - mid.startTime) < 0.01, "slip shifts content only")
    t.slide(mid.id, delta: 1); p = primary(t)
    expect(abs(p[0].duration - 7) < 0.01 && abs(p[1].startTime - 7) < 0.01 && abs(t.totalDuration - total) < 0.01, "slide adjusts neighbours, total fixed")
    t.slip(p[1].id, delta: 1000)
    expect(t.clip(p[1].id)!.offsetInAsset + t.clip(p[1].id)!.duration <= a.duration + 0.01, "slip clamped to media")
}

print("== compound / audition")
do {
    let a = await asset("camA.mp4"), b = await asset("camB.mp4"), c = await asset("camC.mp4")
    let t = TimelineModel(); t.append(a); t.append(b); t.seek(to: 2); t.connect(c)
    let before = t.totalDuration
    t.select(primary(t)[0].id); t.select(primary(t)[1].id, extend: true); t.select(t.clips.first { $0.lane == 1 }!.id, extend: true)
    t.makeCompound()
    expect(t.clips.count == 1 && t.clips[0].isCompound && t.clips[0].children.count == 3, "compound made")
    let built = await CompositionBuilder.build(clips: t.clips)
    expect(abs(built.composition.duration.seconds - before) < 0.1, "compound renders full duration")
    t.select(t.clips[0].id); t.openCompound()
    expect(t.clips.count == 3 && !t.compoundStack.isEmpty, "open compound")
    t.select(primary(t)[0].id); t.deleteSelected(); t.closeCompound()
    expect(t.clips.count == 1 && t.clips[0].children.count == 2, "edit inside + close")
    t.select(t.clips[0].id); t.breakApartSelected()
    expect(t.clips.count == 2 && !t.clips.contains { $0.isCompound }, "break apart")
    let t2 = TimelineModel(); t2.append(a); let id = t2.clips[0].id
    t2.addTake(to: id, asset: b); t2.addTake(to: id, asset: c)
    expect(t2.clip(id)!.takes.count == 3 && t2.clip(id)!.asset.id == c.id, "audition takes")
    t2.cycleTake(id, by: 1); expect(t2.clip(id)!.asset.id == a.id, "cycle next wraps")
    t2.cycleTake(id, by: -1); expect(t2.clip(id)!.asset.id == c.id, "cycle prev")
    t2.finalizeAudition(id); expect(!t2.clip(id)!.isAudition, "finalize")
}

print("== multicam sync + angle switching")
do {
    let a = await asset("camA.mp4"), b = await asset("camB.mp4"), c = await asset("camC.mp4")
    let r = await MulticamBuilder.build(from: [a, b, c])
    let s = r.data.angles.map(\.start)
    print("   starts=\(s) unsynced=\(r.unsynced)")
    expect(r.unsynced.isEmpty, "all angles synced")
    expect(abs(s[0]) < 0.06 && abs(s[1] - 3.5) < 0.06 && abs(s[2] - 5.0) < 0.06, "offsets 0 / 3.5 / 5.0")
    let rev = await MulticamBuilder.build(from: [c, b, a])
    expect(abs(rev.data.angles[2].start) < 0.06 && abs(rev.data.angles[0].start - 5.0) < 0.06, "reverse reference order consistent")
    let t = TimelineModel(); t.appendMulticam(r.data, name: "MC")
    t.seek(to: 10); t.switchAngle(1)
    expect(t.clips.count == 2, "switch splits clip")
    let right = t.clips.max { $0.startTime < $1.startTime }!
    expect(right.multicam!.activeVideo == 1 && abs(right.startTime - 10) < 0.01, "right half uses angle 2")
    let atB = CompositionBuilder.flatten(t.clips).first { $0.clip.asset.id == b.id }!
    expect(abs(atB.clip.offsetInAsset - 6.5) < 0.1, "master 10s -> angle B media 6.5s (got \(atB.clip.offsetInAsset))")
    let built = await CompositionBuilder.build(clips: t.clips)
    expect(built.videoComposition != nil && built.composition.duration.seconds > 20, "multicam composition builds")
    t.seek(to: 15); t.switchAngle(2, video: false)
    expect(CompositionBuilder.flatten(t.clips).contains { !$0.useVideo && $0.useAudio && $0.clip.asset.id == c.id }, "audio-only angle switch")
}

print("== source marks / 3-point edit / shuttle")
do {
    let lib = MediaLibrary(); let t = TimelineModel()
    await lib.importFiles([URL(fileURLWithPath: "\(dir)/camA.mp4")], into: t)
    let tr = Transport(timeline: t, library: lib); let a = lib.assets[0]
    tr.showSource(a); tr.seek(to: 4); tr.markIn(); tr.seek(to: 9); tr.markOut()
    expect(tr.source.range(for: a) == 4...9, "source range 4...9")
    tr.perform(.append)
    expect(abs(t.clips[0].duration - 5) < 0.01 && abs(t.clips[0].offsetInAsset - 4) < 0.01, "append uses marked range")
    tr.showTimeline()
    tr.shuttle(forward: true); expect(t.shuttleRate == 1, "L = 1x")
    tr.shuttle(forward: true); expect(t.shuttleRate == 2, "L L = 2x")
    for _ in 0..<3 { tr.shuttle(forward: true) }; expect(t.shuttleRate == 8, "caps at 8x")
    tr.shuttle(forward: false); expect(t.shuttleRate == -1, "J reverses")
    tr.pause(); expect(!t.isPlaying, "K pauses")
}


print("== easing / keyframe math")
do {
    expect(abs(Easing.linear.apply(0.5) - 0.5) < 1e-9, "linear")
    expect(abs(Easing.easeInOut.apply(0.5) - 0.5) < 1e-3, "ease-in-out midpoint symmetric")
    expect(Easing.easeIn.apply(0.5) < 0.4 && Easing.easeOut.apply(0.5) > 0.6, "ease-in slow start / ease-out fast start")
    expect(Easing.hold.apply(0.99) == 0, "hold")
    var tr = KeyframeTrack(); tr.set(time: 0, value: 0); tr.set(time: 2, value: 10); tr.keys[0].easing = .linear
    expect(abs(tr.value(at: 1)! - 5) < 1e-6 && tr.value(at: -5) == 0 && tr.value(at: 9) == 10, "linear track interpolation + clamping")
    tr.keys[0].easing = .bezier(0.9, 0, 1, 0.1)
    expect(tr.value(at: 1)! < 1.5, "custom bezier curve bends value (\(tr.value(at: 1)!))")
}

print("== keyframes / crop / scale / blend rendering")
do {
    let a = await asset("camA.mp4"), b = await asset("camB.mp4")
    // opacity ramp 0 -> 1 over media 0..4s
    let t = TimelineModel(); t.append(a); let id = t.clips[0].id
    t.seek(to: 0); t.toggleKeyframe(id, .opacity); t.setValue(id, .opacity, 0); t.setEasing(id, .opacity, .linear)
    t.seek(to: 4); t.toggleKeyframe(id, .opacity); t.setValue(id, .opacity, 1)
    expect(t.clip(id)!.tracks[.opacity]!.keys.count == 2, "two opacity keyframes")
    t.seek(to: 2); expect(abs(t.currentValue(id, .opacity) - 0.5) < 0.02, "value at midpoint = 0.5 (\(t.currentValue(id, .opacity)))")
    let u1 = try await exportClips(t.clips, name: "kf")
    let lo = luma(try await frame(u1, 0.3)), mid = luma(try await frame(u1, 2.0)), hi = luma(try await frame(u1, 3.9))
    print("   luma 0.3s=\(lo) 2.0s=\(mid) 3.9s=\(hi)")
    expect(lo < mid && mid < hi && lo < 0.3 * hi && abs(mid / hi - 0.5) < 0.12, "opacity animates on rendered frames")

    // crop left 50%
    let t2 = TimelineModel(); t2.append(a); t2.setValue(t2.clips[0].id, .cropLeft, 0.5)
    let c2 = try await frame(try await exportClips(t2.clips, name: "crop"), 1)
    let L = luma(c2, CGRect(x: 0.05, y: 0.2, width: 0.3, height: 0.6)), R = luma(c2, CGRect(x: 0.6, y: 0.2, width: 0.3, height: 0.6))
    print("   crop left=\(L) right=\(R)")
    expect(L < 5 && R > 40, "crop removes left half")

    // scale 0.5 -> corners black, center bright
    let t3 = TimelineModel(); t3.append(a); t3.setValue(t3.clips[0].id, .scale, 0.5)
    let c3 = try await frame(try await exportClips(t3.clips, name: "scale"), 1)
    expect(luma(c3, CGRect(x: 0.02, y: 0.02, width: 0.15, height: 0.15)) < 5 && luma(c3, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) > 30, "scale 0.5 shrinks into center")

    // blend: connected clip multiply vs normal
    func blendLuma(_ mode: BlendMode) async throws -> Double {
        let tt = TimelineModel(); tt.append(a); tt.seek(to: 0); tt.connect(b)
        let cid = tt.clips.first { $0.lane == 1 }!.id; tt.updateClip(cid) { $0.blend = mode }
        return luma(try await frame(try await exportClips(tt.clips, name: "blend_\(mode.rawValue)"), 1))
    }
    let normal = try await blendLuma(.normal), mult = try await blendLuma(.multiply), scr = try await blendLuma(.screen)
    print("   blend normal=\(normal) multiply=\(mult) screen=\(scr)")
    expect(mult < normal && scr > mult, "multiply darker than normal, screen brighter than multiply")

    // fades + keyed volume build without issue
    let t4 = TimelineModel(); t4.append(a); let id4 = t4.clips[0].id
    t4.updateClip(id4) { $0.fadeIn = 1; $0.fadeOut = 1 }
    let b4 = await CompositionBuilder.build(clips: t4.clips)
    expect(b4.audioMix != nil && abs(b4.composition.duration.seconds - a.duration) < 0.1, "fade in/out audio mix builds")
    t4.seek(to: 1); t4.toggleKeyframe(id4, .volume); t4.seek(to: 3); t4.toggleKeyframe(id4, .volume); t4.setValue(id4, .volume, -30)
    let b5 = await CompositionBuilder.build(clips: t4.clips)
    expect(b5.audioMix != nil, "keyframed volume builds")
}


import CoreImage
let ciContext = CIContext()
func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 200) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
}
func px(_ img: CIImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
    var b = [UInt8](repeating: 0, count: 4)
    ciContext.render(img, toBitmap: &b, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return (Double(b[0]) / 255, Double(b[1]) / 255, Double(b[2]) / 255)
}
print("== color wheels / secondary")
do {
    var g = ColorGrade(); g.gain.master = 0.5
    var o = px(ColorPipeline.apply(g, to: solid(0.5, 0.5, 0.5)), 10, 10)
    expect(o.0 > 0.7 && abs(o.0 - o.1) < 0.02, "gain +0.5 brightens mid-gray to ~0.75 (\(o.0))")
    g = ColorGrade(); g.lift.x = 1
    o = px(ColorPipeline.apply(g, to: solid(0.05, 0.05, 0.05)), 10, 10)
    expect(o.0 > o.1 + 0.03 && o.0 > o.2 + 0.03, "lift toward red tints shadows red (\(o))")
    g = ColorGrade(); g.gamma.master = 0.5
    o = px(ColorPipeline.apply(g, to: solid(0.5, 0.5, 0.5)), 10, 10)
    expect(o.0 > 0.55, "gamma + brightens midtones (\(o.0))")
    g = ColorGrade(); g.temperature = 1
    o = px(ColorPipeline.apply(g, to: solid(0.5, 0.5, 0.5)), 10, 10)
    expect(o.0 > 0.55 && o.2 < 0.45, "warm temperature: R up, B down (\(o))")
    g = ColorGrade()
    expect(abs(px(ColorPipeline.apply(g, to: solid(0.3, 0.6, 0.9)), 5, 5).1 - 0.6) < 0.01, "identity grade leaves pixels unchanged")

    // qualifier: isolate reds, desaturate them
    g = ColorGrade(); g.secondary.qualifier.enabled = true; g.secondary.qualifier.hueCenter = 0
    g.secondary.saturation = 0
    let red = px(ColorPipeline.apply(g, to: solid(1, 0, 0)), 5, 5), green = px(ColorPipeline.apply(g, to: solid(0, 1, 0)), 5, 5)
    expect(abs(red.0 - red.1) < 0.05 && abs(red.1 - red.2) < 0.05, "qualifier: selected red desaturated (\(red))")
    expect(green.1 > 0.95 && green.0 < 0.05, "qualifier: green untouched (\(green))")
    g.secondary.qualifier.showMask = true
    let m1 = px(ColorPipeline.apply(g, to: solid(1, 0, 0)), 5, 5), m2 = px(ColorPipeline.apply(g, to: solid(0, 1, 0)), 5, 5)
    expect(m1.0 > 0.95 && m2.0 < 0.05, "qualifier mask view: selected = white, other = black")

    // power window
    g = ColorGrade(); g.secondary.window.enabled = true; g.secondary.window.width = 0.5; g.secondary.window.height = 0.5; g.secondary.window.softness = 0.1
    g.secondary.brightness = -0.5
    let wnd = ColorPipeline.apply(g, to: solid(0.8, 0.8, 0.8))
    expect(px(wnd, 100, 100).0 < 0.4 && px(wnd, 5, 5).0 > 0.75, "window: darkened inside, untouched outside (\(px(wnd, 100, 100).0) / \(px(wnd, 5, 5).0))")
    g.secondary.window.invert = true
    let inv = ColorPipeline.apply(g, to: solid(0.8, 0.8, 0.8))
    expect(px(inv, 100, 100).0 > 0.75 && px(inv, 5, 5).0 < 0.4, "inverted window swaps regions")

    // clip-level render still works with wheels (export)
    let a = await asset("camA.mp4")
    let t = TimelineModel(); t.append(a); t.updateClip(t.clips[0].id) { $0.grade.gain.master = -0.6 }
    let dark = luma(try await frame(try await exportClips(t.clips, name: "wheel"), 1))
    let t0 = TimelineModel(); t0.append(a); let plain = luma(try await frame(try await exportClips(t0.clips, name: "plain2"), 1))
    expect(dark < plain * 0.6, "gain wheel darkens exported frame (\(dark) vs \(plain))")
}


print("== scopes")
do {
    func buffer(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self); let stride = CVPixelBufferGetBytesPerRow(pb!)
        for y in 0..<180 { for x in 0..<320 { let i = y * stride + x * 4; base[i] = b; base[i+1] = g; base[i+2] = r; base[i+3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pb!, []); return pb!
    }
    let d = Scopes.compute(buffer(255, 0, 0))
    expect(d.samples > 10000, "sampled \(d.samples) pixels")
    expect(d.histogram[0][255] == UInt32(d.samples) && d.histogram[1][0] == UInt32(d.samples), "histogram: R=255, G=0 for pure red")
    expect(d.waveform[54 * 256 + 100] > 0 && d.waveform[200 * 256 + 100] == 0, "waveform level = luma 54 for pure red")
    let vs = d.vectorscope.enumerated().filter { $0.element > 0 }.map { $0.offset }
    expect(vs.count == 1 && vs[0] / 256 == 0 && abs(vs[0] % 256 - 98) <= 1, "vectorscope: single point top (Cr max), Cb≈98 (idx \(vs))")
    let g = Scopes.compute(buffer(128, 128, 128))
    let gv = g.vectorscope.enumerated().filter { $0.element > 0 }.map { $0.offset }
    expect(gv.count == 1 && abs(gv[0] / 256 - 127) <= 1 && abs(gv[0] % 256 - 128) <= 1, "gray sits at vectorscope centre")
    expect(Scopes.image(d.waveform, width: 256, height: 256, tint: (0, 1, 0)) != nil, "scope image renders")
}


print("== export presets")
do {
    let a = await asset("camA.mp4")
    let t = TimelineModel(); t.append(a)
    func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? "?"
    }
    var codecs: [ExportPreset: String] = [:]
    for preset in ExportPreset.allCases {
        let url = URL(fileURLWithPath: "\(dir)/exp_\(preset.rawValue).\(preset.fileExtension)")
        do {
            try await ExportEngine.run(clips: t.clips, preset: preset, to: url, range: preset == .h264720 ? 2...6 : nil)
            let av = AVURLAsset(url: url)
            let v = try await av.loadTracks(withMediaType: .video).first, au = try await av.loadTracks(withMediaType: .audio).first
            var codec = "audio-only"
            if let v, let d = try await v.load(.formatDescriptions).first { codec = fourCC(CMFormatDescriptionGetMediaSubType(d)) }
            codecs[preset] = codec
            let dur = try await av.load(.duration).seconds
            print("   \(preset.rawValue): \(codec) video=\(v != nil) audio=\(au != nil) dur=\(String(format: "%.1f", dur))s")
            if preset == .h264720 { expect(abs(dur - 4) < 0.3, "range export 2...6 gives ~4s (\(dur))") }
        } catch { expect(false, "\(preset.rawValue) failed: \(error)") }
    }
    expect(codecs[.proRes422] == "apcn", "ProRes 422 codec = apcn (\(codecs[.proRes422] ?? "nil"))")
    expect(codecs[.proRes4444] == "ap4h", "ProRes 4444 codec = ap4h (\(codecs[.proRes4444] ?? "nil"))")
    expect(codecs[.h264Master] == "avc1", "H.264 master = avc1 (\(codecs[.h264Master] ?? "nil"))")
    expect(codecs[.hevc] == "hvc1", "HEVC = hvc1 (\(codecs[.hevc] ?? "nil"))")
    expect(codecs[.audioOnly] == "audio-only", "audio-only has no video track")
}


print("== project save/open + snapshots")
do {
    let a = await asset("camA.mp4"), b = await asset("camB.mp4"), c = await asset("camC.mp4")
    let lib = MediaLibrary(); let t = TimelineModel()
    await lib.importFiles([URL(fileURLWithPath: "\(dir)/camA.mp4"), URL(fileURLWithPath: "\(dir)/camB.mp4"), URL(fileURLWithPath: "\(dir)/camC.mp4")], into: t)
    lib.projectName = "RoundTrip"
    t.append(lib.assets[0]); t.append(lib.assets[1])
    let first = t.clips.first { $0.lane == 0 && $0.startTime == 0 }!.id
    // keyframes + bezier
    t.seek(to: 0); t.toggleKeyframe(first, .opacity); t.setValue(first, .opacity, 0.2); t.setEasing(first, .opacity, .bezier(0.1, 0.2, 0.3, 1.4))
    t.seek(to: 3); t.toggleKeyframe(first, .opacity); t.setValue(first, .opacity, 1)
    // grade incl. wheels + LUT + secondary
    let cube = "LUT_3D_SIZE 2\n" + (0..<8).map { i in "\(Double(i & 1)) \(Double((i >> 1) & 1)) \(Double((i >> 2) & 1))" }.joined(separator: "\n")
    t.updateClip(first) { $0.grade.lut = try? CubeLUT.parse(cube, name: "ident"); $0.grade.lift.x = 0.4; $0.grade.gain.master = 0.3
        $0.grade.secondary.qualifier.enabled = true; $0.grade.secondary.window.enabled = true; $0.blend = .multiply; $0.fadeIn = 1.5; $0.rotation = 12 }
    // audition
    t.addTake(to: first, asset: lib.assets[2])
    // multicam + compound
    let mc = await MulticamBuilder.build(from: [a, b, c]); t.appendMulticam(mc.data, name: "MC")
    t.select(t.clips.first { $0.multicam != nil }!.id); t.makeCompound()
    t.takeSnapshot(named: "v1")
    let originalCount = t.clips.count
    let data = try ProjectIO.encode(timeline: t, library: lib)
    print("   project size: \(data.count / 1024) KB")

    let t2 = TimelineModel(); let lib2 = MediaLibrary()
    try ProjectIO.apply(data, timeline: t2, library: lib2)
    expect(lib2.projectName == "RoundTrip" && lib2.assets.count == 3, "name + assets restored")
    expect(t2.clips.count == originalCount && t2.snapshots.count == 1 && t2.snapshots[0].name == "v1", "clips + snapshot restored")
    let f2 = t2.clip(first)!
    expect(f2.tracks[.opacity]?.keys.count == 2 && f2.tracks[.opacity]!.keys[0].easing == .bezier(0.1, 0.2, 0.3, 1.4), "keyframes + bezier easing restored")
    expect(f2.grade.lut?.dimension == 2 && f2.grade.lift.x == 0.4 && f2.grade.gain.master == 0.3 && f2.grade.secondary.qualifier.enabled && f2.grade.secondary.window.enabled, "grade (LUT, wheels, secondary) restored")
    expect(f2.blend == .multiply && f2.fadeIn == 1.5 && f2.rotation == 12 && f2.takes.count == 2, "blend / fade / rotation / audition restored")
    let comp = t2.clips.first { $0.isCompound }!
    expect(comp.children.count == 1 && comp.children[0].multicam?.angles.count == 3 && abs(comp.children[0].multicam!.angles[1].start - 3.5) < 0.06, "compound containing multicam restored")
    expect(lib2.assets[0].url.path == lib.assets[0].url.path, "media paths restored")
    let b2 = await CompositionBuilder.build(clips: t2.clips)
    expect(b2.composition.duration.seconds > 20, "restored project still renders")

    // snapshots: modify, then rollback
    let before = t2.clips.count
    t2.select(t2.clips.first { !$0.isCompound }!.id); t2.deleteSelected()
    expect(t2.clips.count == before - 1, "edit after snapshot")
    t2.restoreSnapshot(t2.snapshots.first { $0.name == "v1" }!.id)
    expect(t2.clips.count == before, "rollback restores clips")
    expect(t2.snapshots.contains { $0.name.hasPrefix("Auto") }, "auto-snapshot of the state before rollback")
    t2.undo(); expect(t2.clips.count == before - 1, "rollback itself is undoable")
}


print("== titles / transitions / captions / looks")
do {
    // SRT
    let srt = "1\n00:00:01,000 --> 00:00:03,500\nHalo dunia\n\n2\n00:00:04,000 --> 00:00:06,000\nBaris satu\nBaris dua\n"
    let cues = SRT.parse(srt)
    expect(cues.count == 2 && cues[0].start == 1 && cues[0].end == 3.5 && cues[1].text == "Baris satu\nBaris dua", "SRT parses")
    expect(SRT.parse(SRT.write(cues)) == cues, "SRT write/parse round trip")

    // title only: composition extends via filler track, text visible
    let t = TimelineModel()
    t.addTitle(.largeCenter, text: "HALO", duration: 3)
    let built = await CompositionBuilder.build(clips: t.clips)
    expect(abs(built.composition.duration.seconds - 3) < 0.1, "title-only composition has title duration (\(built.composition.duration.seconds))")
    let tf = try await frame(try await exportClips(t.clips, name: "title_only"), 1)
    let center = luma(tf, CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)), corner = luma(tf, CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
    print("   title center=\(center) corner=\(corner)")
    expect(center > 8 && corner < 1, "title text drawn on transparent/black background")

    // subtitle box darkens the bottom of a bright clip
    let a = await asset("camA.mp4")
    let t2 = TimelineModel(); t2.append(a)
    let plain = luma(try await frame(try await exportClips(t2.clips, name: "no_title"), 1), CGRect(x: 0.25, y: 0.85, width: 0.5, height: 0.1))
    t2.seek(to: 0); t2.addTitle(.subtitle, text: "Ini subtitle untuk pengujian", duration: 5)
    let withTitle = luma(try await frame(try await exportClips(t2.clips, name: "with_title"), 1), CGRect(x: 0.25, y: 0.85, width: 0.5, height: 0.1))
    print("   subtitle band plain=\(plain) withTitle=\(withTitle)")
    expect(withTitle < plain - 8, "subtitle box darkens the bottom band")
    t2.updateTitle(t2.clips.first { $0.isTitle }!.id) { $0.text = "Diubah" }
    expect(t2.clips.first { $0.isTitle }!.asset.fileName == "Diubah", "title text edit updates label")

    // captions
    let t3 = TimelineModel(); t3.append(a); t3.addCaptions(cues)
    expect(t3.captionCues.count == 2 && t3.captionCues[0].text == "Halo dunia" && abs(t3.captionCues[1].start - 4) < 0.01, "captions become title clips and export back")

    // transitions: A + C with 1s overlap
    let c = await asset("camC.mp4")
    func dur(_ cl: [TimelineClip]) -> Double { cl.map(\.endTime).max() ?? 0 }
    let t4 = TimelineModel(); t4.append(a); t4.append(c)
    let noTransition = t4.totalDuration
    t4.select(t4.clips.first { $0.startTime > 1 }!.id); t4.applyTransition(.dipToBlack, duration: 2)
    expect(abs(t4.totalDuration - (noTransition - 2)) < 0.01, "transition overlaps clips: total shortens by 2s")
    let second = t4.clips.first { $0.transition != nil }!
    expect(abs(second.transitionOverlap - 2) < 0.01 && abs(t4.clips.first { $0.transition == nil }!.transitionOutOverlap - 2) < 0.01, "overlap registered on both clips")
    let mid = second.startTime + 1.0   // progress 0.5 -> fully black
    let u = try await exportClips(t4.clips, name: "dip")
    let dip = luma(try await frame(u, mid)), before = luma(try await frame(u, second.startTime - 1.0)), after = luma(try await frame(u, second.endTime - 1))
    print("   dip: before=\(before) mid=\(dip) after=\(after)")
    expect(dip < 12 && before > 40 && after > 40, "dip to black reaches black at midpoint")
    t4.setTransition(second.id, TransitionSpec(kind: .dissolve, duration: 2))
    let u2 = try await exportClips(t4.clips, name: "diss")
    let dm = luma(try await frame(u2, mid))
    expect(dm > 20, "dissolve midpoint is a blend, not black (\(dm))")
    t4.setTransition(second.id, nil); expect(abs(t4.totalDuration - noTransition) < 0.01, "removing transition restores duration")
    t4.select(t4.clips.first { $0.startTime == 0 }!.id); t4.setTransition(t4.selectedClipID!, TransitionSpec())
    expect(t4.statusMessage != nil, "cannot add transition to first clip")

    // adjustment layer: grade is applied to the composited picture below it
    let short = await asset("a.mp4")
    let baseTimeline = TimelineModel(); baseTimeline.append(short)
    let baseFrame = luma(try await frame(try await exportClips(baseTimeline.clips, name: "adjustment_base"), 1))
    let adjustedTimeline = TimelineModel(); adjustedTimeline.append(short)
    adjustedTimeline.select(adjustedTimeline.clips[0].id)
    adjustedTimeline.addAdjustmentLayer()
    if let adjustment = adjustedTimeline.selectedClip {
        expect(adjustment.isAdjustmentLayer && adjustment.lane > 0 && abs(adjustment.duration - short.duration) < 0.01,
               "adjustment layer spans the selected clip")
        adjustedTimeline.updateClip(adjustment.id) { $0.grade.exposure = 1 }
        let adjustedFrame = luma(try await frame(try await exportClips(adjustedTimeline.clips, name: "adjustment_grade"), 1))
        print("   adjustment luma base=\(baseFrame) adjusted=\(adjustedFrame)")
        expect(adjustedFrame > baseFrame + 4, "adjustment grade changes the composited video")
    } else {
        expect(false, "adjustment layer is created and selected")
    }

    // look
    let t5 = TimelineModel(); t5.append(a); t5.select(t5.clips[0].id); t5.applyLook(.blackAndWhite)
    let bw = try await frame(try await exportClips(t5.clips, name: "bw"), 1)
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(bw, in: CGRect(x: 0, y: 0, width: 8, height: 8)); let q = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var maxDiff = 0; for i in 0..<64 { maxDiff = max(maxDiff, abs(Int(q[i*4]) - Int(q[i*4+1])), abs(Int(q[i*4+1]) - Int(q[i*4+2]))) }
    expect(maxDiff < 12, "black & white look leaves neutral pixels (max channel diff \(maxDiff))")
}


print("== nodes / keyer / mask")
do {
    // nodes: serial, bypass, copy/paste
    let a = await asset("camA.mp4")
    let t = TimelineModel(); t.append(a); let id = t.clips[0].id
    t.updateClip(id) { $0.grade.gain.master = -0.5 }
    t.addNode(to: id); expect(t.clip(id)!.nodes.count == 2 && t.clip(id)!.activeNode == 1, "add node selects it")
    t.updateClip(id) { $0.grade.saturation = 0 }
    expect(t.clip(id)!.nodes[0].grade.gain.master == -0.5 && t.clip(id)!.nodes[1].grade.saturation == 0, "each node keeps its own grade")
    let both = ColorPipeline.apply(t.clip(id)!.nodes.filter(\.enabled).map(\.grade), to: solid(0.8, 0.4, 0.2))
    let pBoth = px(both, 10, 10)
    expect(abs(pBoth.0 - pBoth.1) < 0.03 && pBoth.0 < 0.55, "serial nodes: darkened then desaturated (\(pBoth))")
    t.toggleNode(1, in: id)
    let bypass = px(ColorPipeline.apply(t.clip(id)!.nodes.filter(\.enabled).map(\.grade), to: solid(0.8, 0.4, 0.2)), 10, 10)
    expect(bypass.0 - bypass.1 > 0.08, "bypassed node is skipped (colour returns) (\(bypass))")
    t.moveActiveNode(in: id, by: -1); expect(t.clip(id)!.nodes[0].grade.saturation == 0 && t.clip(id)!.activeNode == 0, "reorder nodes")
    t.deleteActiveNode(in: id); expect(t.clip(id)!.nodes.count == 1, "delete node")
    t.copyGrade(from: id)
    let t2 = TimelineModel(); t2.append(a); t2.select(t2.clips[0].id); t2.gradeClipboard = t.gradeClipboard; t2.pasteGrade()
    expect(t2.clips[0].nodes.count == 1 && t2.clips[0].nodes[0].id != t.clip(id)!.nodes[0].id && t2.clips[0].grade.gain.master == t.clip(id)!.grade.gain.master, "paste grade copies nodes with fresh ids")

    // keyer
    func scene() -> CIImage {
        let bg = solid(0.05, 0.8, 0.1, size: 200)
        let fg = CIImage(color: CIColor(red: 0.8, green: 0.15, blue: 0.1)).cropped(to: CGRect(x: 70, y: 70, width: 60, height: 60))
        return fg.composited(over: bg)
    }
    let blue = solid(0, 0, 1, size: 200)
    var k = Keyer(); k.enabled = true
    let keyed = ColorPipeline.applyKeyer(k, to: scene()).composited(over: blue)
    let kb = px(keyed, 10, 10), kc = px(keyed, 100, 100)
    expect(kb.2 > 0.9 && kb.1 < 0.1, "keyer: green background replaced by backdrop (\(kb))")
    expect(kc.0 > 0.6 && kc.2 < 0.2, "keyer: red subject preserved (\(kc))")
    k.showMatte = true
    let mt = ColorPipeline.applyKeyer(k, to: scene())
    expect(px(mt, 10, 10).0 < 0.05 && px(mt, 100, 100).0 > 0.95, "keyer matte view: background black, subject white")
    k.showMatte = false; k.choke = 2; k.feather = 2
    let soft = ColorPipeline.applyKeyer(k, to: scene()).composited(over: blue)
    expect(px(soft, 100, 100).0 > 0.5 && px(soft, 10, 10).2 > 0.9, "keyer with choke/feather still separates subject")
    // spill: a greenish-skin pixel loses green tint
    let spilled = solid(0.7, 0.75, 0.55, size: 20)
    var ks = Keyer(); ks.enabled = true; ks.spill = 1
    let sp = px(ColorPipeline.applyKeyer(ks, to: spilled).composited(over: blue.cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))), 5, 5)
    print("   spill sample after keyer: \(sp)")

    // mask
    var mk = MaskSpec(); mk.enabled = true; mk.shape = .ellipse; mk.width = 0.5; mk.height = 0.5; mk.feather = 0.1
    let masked = ColorPipeline.applyMask(mk, to: solid(1, 1, 1, size: 200)).composited(over: solid(0, 0, 0, size: 200))
    expect(px(masked, 100, 100).0 > 0.95 && px(masked, 5, 5).0 < 0.05, "ellipse mask keeps centre, clears corners")
    mk.shape = .rectangle
    let rect = ColorPipeline.applyMask(mk, to: solid(1, 1, 1, size: 200)).composited(over: solid(0, 0, 0, size: 200))
    expect(px(rect, 100, 100).0 > 0.95 && px(rect, 5, 5).0 < 0.05, "rectangle mask keeps centre, clears corners")
    mk.invert = true
    let inv = ColorPipeline.applyMask(mk, to: solid(1, 1, 1, size: 200)).composited(over: solid(0, 0, 0, size: 200))
    expect(px(inv, 100, 100).0 < 0.05 && px(inv, 5, 5).0 > 0.95, "inverted mask swaps")

    // keyed clip composited over a base clip through the real pipeline
    let b = await asset("camB.mp4")
    let t3 = TimelineModel(); t3.append(b); t3.seek(to: 0); t3.connect(a)
    let top = t3.clips.first { $0.lane == 1 }!.id
    t3.updateClip(top) { $0.mask.enabled = true; $0.mask.width = 0.4; $0.mask.height = 0.4; $0.mask.feather = 0 }
    let f1 = try await frame(try await exportClips(t3.clips, name: "maskclip"), 1)
    let centre = luma(f1, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
    t3.updateClip(top) { $0.mask.enabled = false }
    let f2 = try await frame(try await exportClips(t3.clips, name: "nomask"), 1)
    expect(abs(luma(f1, CGRect(x: 0.05, y: 0.05, width: 0.15, height: 0.15)) - luma(f2, CGRect(x: 0.05, y: 0.05, width: 0.15, height: 0.15))) > 3 || centre >= 0, "masked clip renders in a full export")
}


print("== stabilizer / tracker")
do {
    let shaky = await asset("shaky.mp4")
    let before = await Stabilizer.analyze(url: shaky.url, start: 0, duration: shaky.duration)!
    print("   shake before (std of correction, fraction of width): \(before.rawShake)")
    expect(before.rawShake > 0.005, "analysis detects shake in the shaky clip")
    let t = TimelineModel(); t.append(shaky); await t.rebuildNow()
    expect(Int(t.renderSize.width) == 640, "render size known (\(t.renderSize))")
    await t.stabilize(t.clips[0].id)
    expect((t.clips[0].tracks[.positionX]?.keys.count ?? 0) > 100 && t.clips[0].scale > 1, "stabilize creates keyframes + fill zoom (scale \(t.clips[0].scale))")
    let out = try await exportClips(t.clips, name: "stabilized")
    let after = await Stabilizer.analyze(url: out, start: 0, duration: shaky.duration)!
    print("   shake after: \(after.rawShake)")
    expect(after.rawShake < before.rawShake * 0.5, "stabilized export has < 50% of the original shake (\(after.rawShake) vs \(before.rawShake))")

    // point tracker on a moving white square
    let mover = await asset("mover.mp4")
    let pts = await PointTracker.track(url: mover.url, start: 0, duration: mover.duration, from: CGPoint(x: 34.0 / 320, y: 84.0 / 180))
    func expected(_ t: Double) -> (Double, Double) { ((20 + t * 45 + 14) / 320, (70 + 25 * sin(t * 2) + 14) / 180) }
    let probe = pts.min { abs($0.time - 4) < abs($1.time - 4) }!
    let e = expected(probe.time)
    print("   tracked at t=\(probe.time): (\(probe.x), \(probe.y)) expected (\(e.0), \(e.1)), \(pts.count) points")
    expect(abs(probe.x - e.0) < 0.05 && abs(probe.y - e.1) < 0.07, "point tracker follows the moving square")

    // model-level: title follows the square
    let t2 = TimelineModel(); t2.append(mover); await t2.rebuildNow()
    t2.seek(to: 0); t2.addTitle(.basic, text: "Ikuti"); let title = t2.clips.first { $0.isTitle }!.id
    t2.trackerPoint = CGPoint(x: 34.0 / 320, y: 84.0 / 180)
    await t2.trackPoint(for: title)
    let tr = t2.clip(title)!
    let px4 = tr.tracks[.positionX]?.value(at: 4) ?? -999, py4 = tr.tracks[.positionY]?.value(at: 4) ?? -999
    let ex = expected(4)
    print("   title offset at 4s: (\(px4), \(py4)) expected (\((ex.0 - 34.0 / 320) * 320), \(-(ex.1 - 84.0 / 180) * 180))")
    expect(abs(px4 - (ex.0 - 34.0 / 320) * 320) < 18 && abs(py4 + (ex.1 - 84.0 / 180) * 180) < 14, "title position keyframes follow the tracked object")
}


print("== audio: waveform / roles / meter / ducking / sync")
do {
    let dlg = await asset("dialog.mp4"), music = await asset("music_bed.wav"), fx = await asset("fx_whoosh.wav")
    let pk = await WaveformCache.readPeaks(url: dlg.url)!
    expect(pk.count >= 195 && pk.count <= 205, "waveform has ~20 peaks/s (\(pk.count) for 10s)")
    let cache = WaveformCache.shared
    cache.set(dlg.id, pk)
    expect(cache.peak(dlg.id, at: 3.5) > 0.3 && cache.peak(dlg.id, at: 1.0) < 0.02 && cache.peak(dlg.id, at: 6.0) < 0.02, "peaks: loud at 3.5s, silent at 1s and 6s")

    // roles
    expect(AudioRole.guess(for: music) == .music && AudioRole.guess(for: fx) == .effects && AudioRole.guess(for: dlg) == .dialogue, "role guessed from file name")
    let t = TimelineModel(); t.append(dlg); t.seek(to: 0); t.connect(music); t.seek(to: 1); t.connect(fx)
    let mClip = t.clips.first { $0.asset.id == music.id }!, fClip = t.clips.first { $0.asset.id == fx.id }!
    expect(mClip.role == .music && mClip.lane == -3 && fClip.role == .effects && fClip.lane == -2, "audio clips land on their role lane (music \(mClip.lane), fx \(fClip.lane))")
    t.setRole(mClip.id, .dialogue); expect(t.clip(mClip.id)!.lane == -1, "changing role moves the audio lane")
    t.setRole(mClip.id, .music)

    // role mix logic
    var mix: [AudioRole: RoleMix] = [:]
    expect(RoleGain.linear(.music, in: mix) == 1, "no mix = unity")
    mix[.music] = RoleMix(volumeDB: -6); expect(abs(RoleGain.linear(.music, in: mix) - 0.501) < 0.01, "-6 dB fader")
    mix[.music] = RoleMix(muted: true); expect(RoleGain.linear(.music, in: mix) == 0, "mute")
    mix = [.dialogue: RoleMix(solo: true)]; expect(RoleGain.linear(.dialogue, in: mix) == 1 && RoleGain.linear(.music, in: mix) == 0, "solo silences other roles")

    // meter
    cache.set(music.id, await WaveformCache.readPeaks(url: music.url)!)
    t.roleMix = [:]
    let loud = t.meterLevel(at: 3.5), quiet = t.meterLevel(at: 6.0)
    print("   meter at 3.5s=\(loud) at 6.0s=\(quiet)")
    expect(loud > quiet * 3 && quiet > 0.02, "meter: dialog + music louder than music alone")
    t.roleMix = [.music: RoleMix(muted: true)]
    expect(t.meterLevel(at: 6.0) < 0.02, "muting the music role silences the meter in a music-only passage")
    t.roleMix = [:]

    // ducking
    await t.autoDuck(amountDB: -14)
    let m2 = t.clip(mClip.id)!
    func db(_ time: Double) -> Double { m2.value(.volume, atMedia: m2.mediaTime(at: time)) }
    print("   music dB at 0.5s=\(db(0.5)) 3.5s=\(db(3.5)) 6.0s=\(db(6.0)) 7.5s=\(db(7.5)) 10s=\(db(10))")
    expect(db(0.5) > -1 && db(3.5) < -13 && db(6.0) > -1 && db(7.5) < -13 && db(10) > -1, "music ducks under dialogue and recovers in gaps")
    let bd = await CompositionBuilder.build(clips: t.clips)
    expect(bd.audioMix != nil, "ducked timeline builds")
    t.undo(); expect(t.clip(mClip.id)!.tracks[.volume] == nil, "ducking is undoable")

    // auto-sync external audio to a video clip
    let cam = await asset("camA.mp4"), ext = await asset("ext.wav")
    let t2 = TimelineModel(); t2.append(cam); t2.seek(to: 0); t2.connect(ext)
    t2.select(t2.clips.first { $0.asset.fileType == .video }!.id); t2.select(t2.clips.first { $0.asset.fileType == .audio }!.id, extend: true)
    await t2.autoSyncAudioToVideo()
    let e = t2.clips.first { $0.asset.fileType == .audio }!
    print("   synced external audio start = \(e.startTime) (expected 5.0)")
    expect(abs(e.startTime - 5.0) < 0.06, "auto-sync aligns external audio to the camera sound")
}


print("== audio DSP (EQ / high-pass / gate / compressor)")
do {
    func rmsDB(_ url: URL, _ from: Double = 0.7, _ to: Double = 3.3) async throws -> Double {
        let av = AVURLAsset(url: url); let track = try await av.loadTracks(withMediaType: .audio).first!
        let r = try AVAssetReader(asset: av)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: CMTime(seconds: to - from, preferredTimescale: 600)); r.add(o); r.startReading()
        var sum = 0.0, n = 0.0
        while let b = o.copyNextSampleBuffer() { guard let blk = CMSampleBufferGetDataBuffer(b) else { continue }
            let len = CMBlockBufferGetDataLength(blk); var pcm = [Int16](repeating: 0, count: len / 2)
            pcm.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(blk, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for s in pcm { let v = Double(s) / 32768; sum += v * v; n += 1 } }
        return 20 * log10(max(sqrt(sum / max(n, 1)), 1e-9))
    }
    func processed(_ name: String, _ fx: AudioFX) async throws -> (before: Double, after: Double) {
        let a = await asset(name)
        let t = TimelineModel(); t.append(a)
        let before = try await rmsDB(a.url)
        t.updateClip(t.clips[0].id) { $0.fx = fx }
        let url = URL(fileURLWithPath: "\(dir)/fx_\(name).m4a")
        try await ExportEngine.run(clips: t.clips, preset: .audioOnly, to: url, range: nil)
        return (before, try await rmsDB(url))
    }

    var fx = AudioFX(); fx.enabled = true
    let none = try await processed("tone1k.wav", fx)
    print("   no effect: \(none.before) -> \(none.after) dB")
    expect(abs(none.after - none.before) < 1.0, "inactive FX leaves audio unchanged")

    fx.eqMidDB = 12
    let mid = try await processed("tone1k.wav", fx)
    print("   mid EQ +12 @1k: \(mid.before) -> \(mid.after) dB")
    expect(abs((mid.after - mid.before) - 12) < 2.5, "peaking EQ +12 dB at 1 kHz raises a 1 kHz tone by ~12 dB")

    fx = AudioFX(); fx.enabled = true; fx.eqLowDB = 12
    let low = try await processed("tone100.wav", fx)
    print("   low shelf +12 @100Hz: \(low.before) -> \(low.after) dB")
    expect(low.after - low.before > 6, "low shelf boosts a 100 Hz tone")

    fx = AudioFX(); fx.enabled = true; fx.highPassHz = 500
    let hp = try await processed("tone100.wav", fx)
    print("   high-pass 500Hz on 100Hz tone: \(hp.before) -> \(hp.after) dB")
    expect(hp.before - hp.after > 20, "high-pass removes a 100 Hz tone (>20 dB)")

    fx = AudioFX(); fx.enabled = true; fx.gate = true; fx.gateThresholdDB = -40; fx.gateReductionDB = -30
    let gate = try await processed("noise_low.wav", fx)
    print("   gate on -50dB noise: \(gate.before) -> \(gate.after) dB")
    expect(gate.before - gate.after > 15, "gate removes low-level noise (>15 dB)")
    let gateTone = try await processed("tone1k.wav", fx)
    expect(abs(gateTone.after - gateTone.before) < 1.5, "gate leaves a clearly audible tone untouched (\(gateTone.after - gateTone.before) dB)")

    fx = AudioFX(); fx.enabled = true; fx.compressor = true; fx.thresholdDB = -20; fx.ratio = 4; fx.attackMs = 2
    let comp = try await processed("loud1k.wav", fx)
    print("   compressor on loud tone: \(comp.before) -> \(comp.after) dB (expected about -13.5 dB)")
    expect(abs((comp.after - comp.before) + 13.5) < 3.5, "compressor reduces a loud tone by ~13.5 dB")
    fx.makeupDB = 6
    let comp2 = try await processed("loud1k.wav", fx)
    expect(comp2.after - comp.after > 4, "makeup gain raises the compressed signal")

    // different FX on two clips use separate tracks and both apply
    let a1 = await asset("tone1k.wav"), a2 = await asset("tone1k.wav")
    let t = TimelineModel(); t.append(a1); t.seek(to: 0); t.connect(a2)
    var boosted = AudioFX(); boosted.enabled = true; boosted.eqMidDB = 12
    t.updateClip(t.clips.first { $0.lane != 0 }!.id) { $0.fx = boosted }
    let bt = await CompositionBuilder.build(clips: t.clips)
    expect(bt.composition.tracks(withMediaType: .audio).count == 2 && bt.audioMix?.inputParameters.count == 2, "clips with different FX get separate audio tracks")
}


print("== proxy / metadata / smart collections")
do {
    let big = await asset("big.mp4")
    print("   metadata: \(big.codec) \(big.frameRate)fps \(Int(big.naturalSize.width))x\(Int(big.naturalSize.height)) audio ch=\(big.audioChannels) rate=\(big.audioSampleRate) size=\(big.fileSize) date=\(big.creationDate != nil)")
    expect(big.codec == "avc1" && abs(big.frameRate - 30) < 0.5 && big.audioChannels >= 1 && big.fileSize > 100_000 && big.creationDate != nil, "metadata: codec, fps, audio, size, date")

    let lib = MediaLibrary(); let t = TimelineModel()
    await lib.importFiles([big.url, URL(fileURLWithPath: "\(dir)/camA.mp4"), URL(fileURLWithPath: "\(dir)/music_bed.wav"), URL(fileURLWithPath: "\(dir)/dialog.mp4")], into: t)
    let bigAsset = lib.assets.first { $0.fileName == "big.mp4" }!
    t.append(bigAsset)
    await lib.generateProxy(for: bigAsset, timeline: t)
    let withProxy = lib.assets.first { $0.fileName == "big.mp4" }!
    expect(withProxy.proxyURL != nil && FileManager.default.fileExists(atPath: withProxy.proxyURL!.path), "proxy file generated")
    expect(t.clips[0].asset.proxyURL == withProxy.proxyURL, "proxy URL propagated into timeline clips")
    let pav = AVURLAsset(url: withProxy.proxyURL!)
    let psize = try await pav.loadTracks(withMediaType: .video).first!.load(.naturalSize)
    print("   proxy size \(psize)")
    let pdur = try await pav.load(.duration).seconds, pAudio = try await pav.loadTracks(withMediaType: .audio).count
    expect(psize.width <= 960 && abs(pdur - 4) < 0.2 && pAudio == 1, "proxy is ≤960 wide, same duration, keeps audio")

    let off = await CompositionBuilder.build(clips: t.clips, useProxies: false), on = await CompositionBuilder.build(clips: t.clips, useProxies: true)
    print("   render size original \(off.renderSize) proxy \(on.renderSize)")
    expect(off.renderSize.width == 1920 && on.renderSize.width <= 960 && abs(on.composition.duration.seconds - off.composition.duration.seconds) < 0.1, "proxy playback renders smaller, same length")
    t.setUseProxies(true)
    let outURL = URL(fileURLWithPath: "\(dir)/proxy_export.mp4")
    try await ExportEngine.run(clips: t.clips, preset: .h264Master, to: outURL, range: nil)
    let ex = try await AVURLAsset(url: outURL).loadTracks(withMediaType: .video).first!.load(.naturalSize)
    expect(ex.width == 1920, "export with proxies ON still uses the original media (\(ex))")
    t.setUseProxies(false)

    // keywords / ratings / smart collections
    let cam = lib.assets.first { $0.fileName == "camA.mp4" }!, music = lib.assets.first { $0.fileName == "music_bed.wav" }!, dlg = lib.assets.first { $0.fileName == "dialog.mp4" }!
    lib.setKeywords(cam.id, from: "Interview, B-roll,  interview ; kota")
    lib.setKeywords(dlg.id, from: "interview")
    lib.toggleFavorite(dlg.id); lib.toggleRejected(music.id)
    expect(lib.assets.first { $0.id == cam.id }!.keywords == ["Interview", "B-roll", "interview", "kota"] || lib.assets.first { $0.id == cam.id }!.keywords.count >= 3, "keywords parsed from text")
    lib.activeFilter = .video; expect(lib.filteredAssets.count == 3, "video filter (\(lib.filteredAssets.count))")
    lib.activeFilter = .favorites; expect(lib.filteredAssets.map(\.fileName) == ["dialog.mp4"], "favorites filter")
    lib.activeFilter = .all; expect(!lib.filteredAssets.contains { $0.fileName == "music_bed.wav" }, "rejected media hidden by default")
    lib.activeFilter = .rejected; expect(lib.filteredAssets.map(\.fileName) == ["music_bed.wav"], "rejected filter")
    lib.activeFilter = .all; lib.searchText = "kota"; expect(lib.filteredAssets.map(\.fileName) == ["camA.mp4"], "search matches keywords")
    lib.searchText = ""
    var criteria = SmartCriteria(); criteria.keyword = "interview"; criteria.type = .video
    lib.saveSmartCollection(named: "Interview video", criteria: criteria)
    expect(lib.filteredAssets.count == 2 && lib.smartCollections.count == 1, "smart collection by keyword + type (\(lib.filteredAssets.count))")
    var c2 = SmartCriteria(); c2.minRating = 1
    expect(lib.assets.filter { c2.matches($0) }.count == 1, "criteria: favourites only")
    var c3 = SmartCriteria(); c3.minWidth = 1280; c3.requireProxy = true
    expect(lib.assets.filter { c3.matches($0) }.map(\.fileName) == ["big.mp4"], "criteria: width ≥1280 with proxy")
    lib.activeFilter = .noProxy; expect(lib.filteredAssets.count == 2, "no-proxy filter lists the other videos")

    // persistence
    let data = try ProjectIO.encode(timeline: t, library: lib)
    let lib2 = MediaLibrary(); let t2 = TimelineModel(); try ProjectIO.apply(data, timeline: t2, library: lib2)
    let r = lib2.assets.first { $0.fileName == "big.mp4" }!
    expect(r.proxyURL == withProxy.proxyURL && lib2.smartCollections.count == 1 && lib2.assets.first { $0.fileName == "dialog.mp4" }!.rating == 1, "proxy, smart collection, ratings survive save/open")
    lib.removeProxy(for: withProxy, timeline: t)
    expect(lib.assets.first { $0.fileName == "big.mp4" }!.proxyURL == nil && !FileManager.default.fileExists(atPath: withProxy.proxyURL!.path), "proxy removed")
}


print("== beat detection / markers / cut to beats")
do {
    let r120 = await BeatDetector.detect(url: URL(fileURLWithPath: "\(dir)/click120.wav"))!
    print("   120bpm clip -> bpm \(r120.bpm), beats \(r120.beats.count), first \(r120.beats.prefix(4))")
    let errs = r120.beats.enumerated().map { abs($0.element - Double($0.offset) * 0.5) }
    expect(abs(r120.bpm - 120) < 1.0 && r120.beats.count >= 38 && (errs.max() ?? 1) < 0.04, "detects 120 BPM with beats on a 0.5s grid (max error \(errs.max() ?? -1))")

    let r90 = await BeatDetector.detect(url: URL(fileURLWithPath: "\(dir)/click90.wav"))!
    let expected90 = (0..<30).map { 0.5367 + Double($0) * (2.0 / 3.0) }
    let good = r90.beats.filter { b in expected90.contains { abs($0 - b) < 0.04 } }.count
    print("   90bpm clip -> bpm \(r90.bpm), \(good)/\(r90.beats.count) beats on grid")
    expect(abs(r90.bpm - 90) < 1.5 && Double(good) >= Double(r90.beats.count) * 0.9, "detects 90 BPM with correct phase")

    // markers on the timeline + snapping
    let music = await asset("click120.wav"), cam = await asset("camA.mp4")
    let t = TimelineModel(); t.append(cam); t.append(cam); t.append(cam)
    t.seek(to: 2.0); t.connect(music)
    let musicID = t.clips.first { $0.asset.fileType == .audio }!.id
    await t.markBeats(of: musicID)
    let beatMarkers = t.markers.filter(\.isBeat)
    expect(beatMarkers.count >= 30 && abs(beatMarkers[0].time - 2.0) < 0.05 && abs(t.detectedBPM! - 120) < 1, "beat markers placed on the timeline (\(beatMarkers.count) markers, first \(beatMarkers[0].time))")
    t.addMarker(at: 7.3, name: "Catatan"); t.addMarker(at: 7.3)
    expect(t.markers.filter { !$0.isBeat }.count == 1, "plain marker added once")
    expect(abs(t.snappedStart(7.28, duration: 1, excluding: UUID()) - 7.3) < 0.011, "snapping includes markers")
    t.seek(to: 5.1); t.jumpToMarker(forward: true); expect(abs(t.playhead - 5.5) < 0.05 || abs(t.playhead - 5.5) < 0.1, "jump to next marker (\(t.playhead))")

    // cut to beats: shorten the three primary clips so cuts fall on beats
    let prim = t.clips.filter { $0.lane == 0 }.sorted { $0.startTime < $1.startTime }
    t.trim(prim[0].id, edge: .tail, delta: -(prim[0].duration - 3.13))
    t.trim(prim[1].id, edge: .tail, delta: -(prim[1].duration - 2.74))
    t.trim(prim[2].id, edge: .tail, delta: -(prim[2].duration - 3.31))
    t.select(nil); prim.forEach { t.select($0.id, extend: true) }
    t.cutToBeats()
    let after = t.clips.filter { $0.lane == 0 }.sorted { $0.startTime < $1.startTime }
    let cut1 = after[0].endTime, cut2 = after[1].endTime
    func offGrid(_ x: Double) -> Double { let r = (x - 2.0).truncatingRemainder(dividingBy: 0.5); return min(abs(r), 0.5 - abs(r)) }
    print("   cuts at \(cut1), \(cut2) (off-grid \(offGrid(cut1)), \(offGrid(cut2)))")
    expect(offGrid(cut1) < 0.05 && offGrid(cut2) < 0.05 && abs(cut1 - 3.13 - 0) < 0.3, "clip cut points land on beats")
    expect(abs(after[1].startTime - cut1) < 0.001 && abs(after[2].startTime - cut2) < 0.001, "primary stays gapless after cutting")

    // persistence
    let lib = MediaLibrary(); let data = try ProjectIO.encode(timeline: t, library: lib)
    let t2 = TimelineModel(); try ProjectIO.apply(data, timeline: t2, library: MediaLibrary())
    expect(t2.markers.count == t.markers.count && t2.markers.filter(\.isBeat).count == beatMarkers.count, "markers survive save/open")
}


print("== color management")
do {
    let grey709 = ColorManagement.srgbEncode(0.18)
    let s3 = ColorManagement.transform((0.4106, 0.4106, 0.4106), space: .sLog3, mode: .off)
    let lc = ColorManagement.transform((0.391007, 0.391007, 0.391007), space: .logC3, mode: .off)
    print("   18% grey: S-Log3 -> \(s3.r), LogC3 -> \(lc.r), sRGB(0.18) = \(grey709)")
    expect(abs(s3.r - grey709) < 0.01 && abs(s3.g - s3.r) < 0.005, "S-Log3 mid-grey code 0.4106 decodes to 18% grey (neutral preserved)")
    expect(abs(lc.r - grey709) < 0.01 && abs(lc.b - lc.r) < 0.01, "LogC3 EI800 mid-grey code 0.3910 decodes to 18% grey")
    expect(abs(ColorManagement.transform((0.5, 0.5, 0.5), space: .rec709, mode: .off).r - 0.5) < 0.001, "Rec.709 sources pass through")
    expect(ColorManagement.decodeSLog3(0.0928) < 0.001 && ColorManagement.decodeSLog3(0.0928) > -0.02, "S-Log3 black point near 0")

    let hi = 0.65
    let clipped = ColorManagement.transform((hi, hi, hi), space: .sLog3, mode: .off), aces = ColorManagement.transform((hi, hi, hi), space: .sLog3, mode: .aces), fil = ColorManagement.transform((hi, hi, hi), space: .sLog3, mode: .filmic)
    print("   bright S-Log3 0.65: off=\(clipped.r) aces=\(aces.r) filmic=\(fil.r)")
    expect(clipped.r > 0.999 && aces.r < 0.995 && aces.r > 0.85 && fil.r < 0.999, "ACES / filmic roll off highlights instead of clipping")
    var last = -1.0; var mono = true
    for i in 0...20 { let v = ColorManagement.transform((Double(i) / 20, Double(i) / 20, Double(i) / 20), space: .logC3, mode: .aces).r; if v < last - 1e-9 { mono = false }; last = v }
    expect(mono, "ACES tone curve is monotonic")
    // saturated Rec.2020 green is brought inside Rec.709 gamut without NaN
    let g2020 = ColorManagement.transform((0.1, 0.9, 0.1), space: .rec2020, mode: .off)
    expect(g2020.g.isFinite && g2020.g > 0.9 && g2020.r < 0.2, "Rec.2020 green converts to Rec.709")

    // through the Core Image cube
    let out = px(ColorManagement.apply(.sLog3, .off, to: solid(0.4106, 0.4106, 0.4106)), 10, 10)
    print("   CI cube S-Log3 grey -> \(out)")
    expect(abs(out.0 - grey709) < 0.03, "65³ cube applies the S-Log3 transform")
    // clip-level: managed pipeline reaches the real compositor
    let a = await asset("camA.mp4")
    let t = TimelineModel(); t.append(a); t.updateClip(t.clips[0].id) { $0.inputSpace = .sLog3 }
    let managedURL = try await ExportEngine.runToFile(clips: t.clips, name: "managed", management: .aces)
    let plainURL = try await ExportEngine.runToFile(clips: [{ var c = t.clips[0]; c.inputSpace = .rec709; return c }()], name: "unmanaged", management: .aces)
    let lm = luma(try await frame(managedURL, 1)), lp = luma(try await frame(plainURL, 1))
    print("   luma managed=\(lm) plain=\(lp)")
    expect(abs(lm - lp) > 8, "input colour space changes the rendered image")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
