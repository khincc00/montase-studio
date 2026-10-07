import Foundation

/// Perintah trim di timeline selain drag tepi klip: trim ke playhead, ke range In/Out, dan per frame.
extension TimelineModel {
    /// Klip yang dipangkas: yang terpilih, atau semua klip di bawah playhead bila tidak ada yang terpilih.
    private func trimTargets(at t: Double) -> [UUID] {
        let hit = clips.filter { $0.startTime + 0.03 < t && t < $0.endTime - 0.03 }
        let selected = hit.filter { selectedClipIDs.contains($0.id) }
        return (selected.isEmpty ? hit : selected).map(\.id)
    }

    /// Buang bagian klip sebelum playhead (Trim Start).
    func trimStartToPlayhead() {
        let t = playhead
        let targets = trimTargets(at: t)
        guard !targets.isEmpty else { statusMessage = "Tidak ada klip di bawah playhead."; return }
        for id in targets {
            guard let c = clip(id) else { continue }
            trim(id, edge: .head, delta: t - c.startTime)
        }
    }

    /// Buang bagian klip setelah playhead (Trim End).
    func trimEndToPlayhead() {
        let t = playhead
        let targets = trimTargets(at: t)
        guard !targets.isEmpty else { statusMessage = "Tidak ada klip di bawah playhead."; return }
        for id in targets {
            guard let c = clip(id) else { continue }
            trim(id, edge: .tail, delta: t - c.endTime)
        }
    }

    /// Pangkas klip terpilih agar hanya tersisa bagian di dalam range In/Out.
    func trimToRange() {
        guard let a = markIn, let b = markOut, b > a else {
            statusMessage = "Tandai range In dan Out terlebih dulu."
            return
        }
        let targets = clips.filter { selectedClipIDs.contains($0.id) && $0.endTime > a + 0.03 && $0.startTime < b - 0.03 }
        guard !targets.isEmpty else { statusMessage = "Pilih klip yang bersinggungan dengan range."; return }
        // Ekor dulu supaya posisi kepala klip lain pada lane primary tidak berubah sebelum dipakai.
        for c in targets where b < c.endTime { trim(c.id, edge: .tail, delta: b - c.endTime) }
        for c in targets {
            guard let now = clip(c.id), a > now.startTime else { continue }
            trim(c.id, edge: .head, delta: a - now.startTime)
        }
    }

    /// Geser tepi klip terpilih sebanyak `frames` frame (negatif = ke kiri). Frame ke-1 = 1 / frame rate proyek.
    func nudgeTrim(edge: ClipEdge, frames: Int) {
        guard !selectedClipIDs.isEmpty else { statusMessage = "Pilih klip untuk di-trim."; return }
        let step = Double(frames) / max(1, frameRate)
        for id in selectedClipIDs { trim(id, edge: edge, delta: step) }
    }

    /// Delta trim setelah di-snap ke playhead, marker, dan tepi klip lain (bila snapping aktif).
    func snappedTrimDelta(_ clip: TimelineClip, edge: ClipEdge, delta: Double) -> Double {
        guard snapping else { return delta }
        let threshold = 8 / zoom
        var points = [0, playhead] + markers.map(\.time)
        for c in clips where c.id != clip.id { points += [c.startTime, c.endTime] }
        let edgeTime = (edge == .head ? clip.startTime : clip.endTime) + delta
        var best: Double?
        for p in points {
            let d = p - edgeTime
            if abs(d) < threshold, abs(d) < abs(best ?? .infinity) { best = d }
        }
        return delta + (best ?? 0)
    }
}
