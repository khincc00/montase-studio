import SwiftUI
import Observation

/// Satu kombinasi tombol: tombol utama + modifier. `key` berupa satu karakter huruf kecil atau nama tombol khusus ("space", "left", ...).
struct KeyCombo: Codable, Hashable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    init(_ key: String, _ modifiers: EventModifiers = []) {
        self.key = key
        command = modifiers.contains(.command)
        shift = modifiers.contains(.shift)
        option = modifiers.contains(.option)
        control = modifiers.contains(.control)
    }

    private static let named: [String: KeyEquivalent] = [
        "space": .space, "delete": .delete, "forwardDelete": .deleteForward,
        "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
        "home": .home, "end": .end, "return": .return, "tab": .tab, "pageUp": .pageUp, "pageDown": .pageDown,
    ]

    private static let symbols: [String: String] = [
        "space": "Space", "delete": "⌫", "forwardDelete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "return": "↩", "tab": "⇥", "pageUp": "⇞", "pageDown": "⇟",
    ]

    /// Kode tombol macOS → nama tombol khusus.
    static let keyCodeNames: [UInt16: String] = [
        49: "space", 51: "delete", 117: "forwardDelete", 123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 36: "return", 76: "return", 48: "tab", 116: "pageUp", 121: "pageDown",
    ]

    var keyEquivalent: KeyEquivalent {
        Self.named[key] ?? KeyEquivalent(key.first ?? " ")
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// Contoh: "⌃⌥⇧⌘B".
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (Self.symbols[key] ?? key.uppercased())
    }

    /// Kombinasi yang dipakai macOS/aplikasi sendiri sehingga tidak boleh ditimpa.
    var isReserved: Bool {
        command && !option && !control && !shift && ["q", "h", ","].contains(key)
    }

    /// Dari event keyDown (nil bila tombol tidak bisa dipakai, mis. hanya modifier).
    static func from(keyCode: UInt16, baseCharacter: String?, flags: NSEvent.ModifierFlags) -> KeyCombo? {
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if let name = keyCodeNames[keyCode] { return KeyCombo(name, mods) }
        guard let c = baseCharacter?.lowercased(), c.count == 1, let scalar = c.unicodeScalars.first,
              scalar.value >= 0x21, scalar.value < 0xF700 else { return nil }
        return KeyCombo(c, mods)
    }
}

enum AngleScope: String, CaseIterable { case both, audio, video }

/// Semua perintah yang bisa diberi pintasan.
enum ShortcutAction: Hashable {
    case openProject, saveProject, saveProjectAs, versions, saveVersion, importMedia, exportMovie, exportFCPXML, exportFrame
    case undo, redo
    case connect, insert, append, blade, delete, copy, paste
    case newCompound, breakApart, openCompound, closeCompound, nextKeyframe, previousKeyframe
    case trimStart, trimEnd, trimToRange
    case trimStartBack, trimStartForward, trimEndBack, trimEndForward
    case toggleFavorite, reject, toggleProxy
    case addTake, nextTake, previousTake, finalizeAudition
    case newMulticam, switchAngle(AngleScope, Int)
    case toolSelect, toolTrim, toolBlade, trimMode(TrimMode), toggleSnapping, zoomIn, zoomOut
    case markIn, markOut, clearRange, addMarker, nextMarker, previousMarker
    case playPause, playReverse, pause, playForward, previousFrame, nextFrame, previousEdit, nextEdit, goToStart, goToEnd

    var id: String {
        switch self {
        case .switchAngle(let scope, let n): "switchAngle.\(scope.rawValue).\(n)"
        case .trimMode(let mode): "trimMode.\(mode.rawValue)"
        default: String(describing: self)
        }
    }
}

struct ShortcutDefinition {
    let action: ShortcutAction
    let title: String
    let group: String
    let defaultCombo: KeyCombo?
}

enum ShortcutCatalog {
    static let groupOrder = ["File", "Edit", "Clip", "Trim", "Tools", "Mark", "Playback", "Media", "Audition", "Multicam"]

    static let all: [ShortcutDefinition] = {
        func d(_ a: ShortcutAction, _ title: String, _ group: String, _ key: String? = nil, _ m: EventModifiers = []) -> ShortcutDefinition {
            ShortcutDefinition(action: a, title: title, group: group, defaultCombo: key.map { KeyCombo($0, m) })
        }
        var list: [ShortcutDefinition] = [
            d(.openProject, "Open Project…", "File", "o", .command),
            d(.saveProject, "Save Project", "File", "s", .command),
            d(.saveProjectAs, "Save Project As…", "File", "s", [.command, .shift]),
            d(.versions, "Versions…", "File", "v", [.command, .option]),
            d(.saveVersion, "Save Version", "File", "s", [.command, .option]),
            d(.importMedia, "Import Media…", "File", "i", .command),
            d(.exportMovie, "Export Movie…", "File", "e", .command),
            d(.exportFCPXML, "Export FCPXML…", "File", "e", [.command, .shift]),
            d(.exportFrame, "Export Current Frame as PNG…", "File"),

            d(.undo, "Undo", "Edit", "z", .command),
            d(.redo, "Redo", "Edit", "z", [.command, .shift]),

            d(.connect, "Connect to Primary Storyline", "Clip", "q"),
            d(.insert, "Insert at Playhead", "Clip", "w"),
            d(.append, "Append to Storyline", "Clip", "e"),
            d(.blade, "Blade (potong di playhead)", "Clip", "b", .command),
            d(.delete, "Delete", "Clip", "delete"),
            d(.copy, "Copy Selected Clips", "Clip", "c", .command),
            d(.paste, "Paste Clips at Playhead", "Clip", "v", .command),
            d(.newCompound, "New Compound Clip", "Clip", "g", .option),
            d(.breakApart, "Break Apart Compound Clip", "Clip", "g", [.command, .shift]),
            d(.openCompound, "Open Compound Clip", "Clip", "down", [.command, .option]),
            d(.closeCompound, "Close Compound Clip", "Clip", "up", [.command, .option]),
            d(.nextKeyframe, "Next Keyframe", "Clip", "]", .option),
            d(.previousKeyframe, "Previous Keyframe", "Clip", "[", .option),

            d(.trimStart, "Trim Start ke Playhead", "Trim", "[", .command),
            d(.trimEnd, "Trim End ke Playhead", "Trim", "]", .command),
            d(.trimToRange, "Trim ke Range In/Out", "Trim", "\\", .option),
            d(.trimStartBack, "Trim Start −1 Frame", "Trim"),
            d(.trimStartForward, "Trim Start +1 Frame", "Trim"),
            d(.trimEndBack, "Trim End −1 Frame", "Trim"),
            d(.trimEndForward, "Trim End +1 Frame", "Trim"),

            d(.toolSelect, "Select Tool", "Tools", "a"),
            d(.toolTrim, "Trim Tool", "Tools", "t"),
            d(.toolBlade, "Blade Tool", "Tools", "b"),
        ]
        for (i, mode) in TrimMode.allCases.enumerated() {
            list.append(d(.trimMode(mode), "Trim: \(mode.title)", "Tools", "\(i + 1)", [.command, .option]))
        }
        list += [
            d(.toggleSnapping, "Snapping Hidup/Mati", "Tools", "n"),
            d(.zoomIn, "Zoom In", "Tools", "=", .command),
            d(.zoomOut, "Zoom Out", "Tools", "-", .command),

            d(.markIn, "Set Range Start", "Mark", "i"),
            d(.markOut, "Set Range End", "Mark", "o"),
            d(.clearRange, "Clear Range", "Mark", "x", .option),
            d(.addMarker, "Tambah Marker", "Mark", "m"),
            d(.nextMarker, "Marker Berikutnya", "Mark", ".", .option),
            d(.previousMarker, "Marker Sebelumnya", "Mark", ",", .option),

            d(.playPause, "Play / Pause", "Playback", "space"),
            d(.playReverse, "Play Reverse", "Playback", "j"),
            d(.pause, "Pause", "Playback", "k"),
            d(.playForward, "Play Forward", "Playback", "l"),
            d(.previousFrame, "Previous Frame", "Playback", "left"),
            d(.nextFrame, "Next Frame", "Playback", "right"),
            d(.previousEdit, "Previous Edit", "Playback", "up"),
            d(.nextEdit, "Next Edit", "Playback", "down"),
            d(.goToStart, "Go to Start", "Playback", "home"),
            d(.goToEnd, "Go to End", "Playback", "end"),

            d(.toggleFavorite, "Tandai Favorit", "Media", "f"),
            d(.reject, "Tolak", "Media", "delete", .command),
            d(.toggleProxy, "Pakai Proxy / Media Asli", "Media", "p", [.command, .shift]),

            d(.addTake, "Add Browser Selection as Take", "Audition", "y", [.command, .option]),
            d(.nextTake, "Next Take", "Audition", "right", [.command, .option]),
            d(.previousTake, "Previous Take", "Audition", "left", [.command, .option]),
            d(.finalizeAudition, "Finalize Audition", "Audition", "y", [.command, .option, .shift]),

            d(.newMulticam, "New Multicam Clip dari Pilihan Browser…", "Multicam", "m", [.command, .option]),
        ]
        let scopes: [(AngleScope, String, EventModifiers)] = [(.both, "Switch to Angle", []), (.audio, "Switch Audio to Angle", .option), (.video, "Switch Video to Angle", .control)]
        for (scope, title, mods) in scopes {
            for n in 1...9 { list.append(d(.switchAngle(scope, n), "\(title) \(n)", "Multicam", "\(n)", mods)) }
        }
        return list
    }()

    static let byID: [String: ShortcutDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.action.id, $0) })

    static func definition(_ action: ShortcutAction) -> ShortcutDefinition { byID[action.id]! }
}

/// Penyimpan pintasan: nilai bawaan + perubahan pengguna (disimpan di UserDefaults, bisa diekspor/diimpor sebagai JSON).
@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    private struct Saved: Codable {
        var custom: [String: KeyCombo] = [:]
        var cleared: Set<String> = []
    }

    private static let storageKey = "khcutpro.shortcuts.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private var saved = Saved()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        } else {
            migrateLegacyToolKeys()
        }
    }

    /// Versi lama hanya menyimpan tombol alat Select/Trim/Blade.
    private func migrateLegacyToolKeys() {
        let legacy: [(String, ShortcutAction)] = [("select", .toolSelect), ("trim", .toolTrim), ("blade", .toolBlade)]
        for (name, action) in legacy {
            guard let key = defaults.string(forKey: "khcutpro.shortcut.\(name)"), key.count == 1 else { continue }
            let combo = KeyCombo(key)
            if combo != ShortcutCatalog.definition(action).defaultCombo { saved.custom[action.id] = combo }
        }
        if !saved.custom.isEmpty { persist() }
    }

    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let c = saved.custom[action.id] { return c }
        if saved.cleared.contains(action.id) { return nil }
        return ShortcutCatalog.definition(action).defaultCombo
    }

    /// Teks pintasan untuk label/tooltip ("" bila kosong).
    func label(for action: ShortcutAction) -> String { combo(for: action)?.display ?? "" }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        saved.custom[action.id] != nil || saved.cleared.contains(action.id)
    }

    /// Aksi lain yang sudah memakai kombinasi ini.
    func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutCatalog.all.first { $0.action != action && self.combo(for: $0.action) == combo }?.action
    }

    enum AssignResult: Equatable {
        case ok
        case displaced(ShortcutAction)
        case reserved
    }

    /// Pasang kombinasi. Bila dipakai aksi lain, pintasan aksi itu dikosongkan (dikembalikan sebagai `.displaced`).
    @discardableResult
    func assign(_ combo: KeyCombo?, to action: ShortcutAction) -> AssignResult {
        var result = AssignResult.ok
        if let combo {
            if combo.isReserved { return .reserved }
            if let other = conflict(for: combo, excluding: action) {
                store(nil, for: other)
                result = .displaced(other)
            }
        }
        store(combo, for: action)
        persist()
        return result
    }

    func reset(_ action: ShortcutAction) {
        if let current = ShortcutCatalog.definition(action).defaultCombo, let other = conflict(for: current, excluding: action) {
            store(nil, for: other)
        }
        saved.custom[action.id] = nil
        saved.cleared.remove(action.id)
        persist()
    }

    func resetAll() {
        saved = Saved()
        persist()
    }

    private func store(_ combo: KeyCombo?, for action: ShortcutAction) {
        let isDefault = combo == ShortcutCatalog.definition(action).defaultCombo
        saved.custom[action.id] = nil
        saved.cleared.remove(action.id)
        if isDefault { return }
        if let combo { saved.custom[action.id] = combo } else { saved.cleared.insert(action.id) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.storageKey) }
    }

    // MARK: Ekspor / impor

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(saved)
    }

    /// Mengganti semua perubahan dengan isi file. Entri dengan id tak dikenal diabaikan.
    func importData(_ data: Data) -> Bool {
        guard let s = try? JSONDecoder().decode(Saved.self, from: data) else { return false }
        saved = Saved(custom: s.custom.filter { ShortcutCatalog.byID[$0.key] != nil && !$0.value.isReserved },
                      cleared: s.cleared.filter { ShortcutCatalog.byID[$0] != nil })
        persist()
        return true
    }
}

extension View {
    /// Pasang pintasan dari ShortcutStore (tanpa pintasan bila dikosongkan pengguna).
    @ViewBuilder
    func shortcut(_ action: ShortcutAction, _ store: ShortcutStore) -> some View {
        if let c = store.combo(for: action) {
            keyboardShortcut(c.keyEquivalent, modifiers: c.eventModifiers)
        } else {
            self
        }
    }
}
