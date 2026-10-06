import SwiftUI

/// Riwayat versi project: simpan snapshot bernama dan kembali ke versi mana pun.
struct SnapshotsSheet: View {
    @Environment(TimelineModel.self) private var timeline
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Versi").font(.title3.weight(.semibold))
            HStack {
                TextField("Nama versi (mis. “Rough cut v1”)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Simpan Versi", action: save)
            }

            if timeline.snapshots.isEmpty {
                Text("Belum ada versi tersimpan.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(timeline.snapshots) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.name).lineLimit(1)
                                Text("\(snapshot.date.formatted(date: .abbreviated, time: .shortened)) • \(snapshot.clips.count) klip")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Kembali ke versi ini") { timeline.restoreSnapshot(snapshot.id) }
                            Button(role: .destructive) { timeline.deleteSnapshot(snapshot.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 200)
            }

            HStack {
                Text("Mengembalikan versi menyimpan keadaan sekarang lebih dulu, jadi bisa dibatalkan.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Tutup") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save() {
        timeline.takeSnapshot(named: name)
        name = ""
    }
}
