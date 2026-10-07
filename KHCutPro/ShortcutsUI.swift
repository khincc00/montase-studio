import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pengaturan pintasan: klik kombinasi lalu tekan tombol baru. Esc membatalkan.
struct ShortcutSettingsView: View {
    private let store = ShortcutStore.shared
    @State private var search = ""
    @State private var recording: ShortcutAction?
    @State private var message: String?

    private var groups: [(String, [ShortcutDefinition])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = ShortcutCatalog.all.filter {
            query.isEmpty || $0.title.lowercased().contains(query) || store.label(for: $0.action).lowercased().contains(query)
        }
        return ShortcutCatalog.groupOrder.compactMap { group in
            let items = matches.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Cari perintah atau tombol", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Impor…", action: importFile)
                Button("Ekspor…", action: exportFile)
                Button("Reset Semua") {
                    store.resetAll()
                    message = "Semua pintasan dikembalikan ke bawaan."
                }
            }
            .padding(12)

            List {
                ForEach(groups, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items, id: \.action) { row($0) }
                    }
                }
            }

            Text(message ?? "Klik kombinasi, lalu tekan tombol baru (boleh tanpa modifier). Esc membatalkan. Bila bentrok, pintasan perintah lain dikosongkan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private func row(_ def: ShortcutDefinition) -> some View {
        HStack(spacing: 8) {
            Text(def.title)
            Spacer()
            ShortcutRecorderButton(
                combo: store.combo(for: def.action),
                isRecording: recording == def.action,
                onStart: { recording = def.action; message = nil },
                onCancel: { if recording == def.action { recording = nil } },
                onRecord: { combo in
                    recording = nil
                    switch store.assign(combo, to: def.action) {
                    case .ok: message = nil
                    case .displaced(let other):
                        message = "\(combo.display) dilepas dari “\(ShortcutCatalog.definition(other).title)”."
                    case .reserved: message = "\(combo.display) dipakai sistem dan tidak bisa dipakai."
                    }
                }
            )
            Button { store.assign(nil, to: def.action) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Kosongkan pintasan")
                .disabled(store.combo(for: def.action) == nil)
            Button { store.reset(def.action) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .buttonStyle(.borderless)
                .help("Kembalikan ke bawaan (\(def.defaultCombo?.display ?? "kosong"))")
                .disabled(!store.isCustomized(def.action))
        }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "KHCutPro-shortcuts.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exportData() else { return }
        do { try data.write(to: url); message = "Pintasan diekspor." } catch { message = "Gagal mengekspor: \(error.localizedDescription)" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? Data(contentsOf: url), store.importData(data) { message = "Pintasan diimpor." }
        else { message = "File pintasan tidak valid." }
    }
}

/// Tombol yang menangkap tombol berikutnya saat dalam mode rekam.
struct ShortcutRecorderButton: View {
    let combo: KeyCombo?
    let isRecording: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onRecord: (KeyCombo) -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? onCancel() : onStart()
        } label: {
            Text(isRecording ? "Tekan tombol…" : (combo?.display ?? "Tidak ada"))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
                .frame(width: 120)
        }
        .onChange(of: isRecording) { _, now in now ? startMonitor() : stopMonitor() }
        .onDisappear(perform: stopMonitor)
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { onCancel(); return nil } // Esc
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let combo = KeyCombo.from(keyCode: event.keyCode, baseCharacter: event.characters(byApplyingModifiers: []), flags: flags) {
                onRecord(combo)
            }
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
