# MONTASE STUDIO

Editor video macOS (SwiftUI + AVFoundation + Core Image) dengan tata letak dan alur kerja ala Final Cut Pro: Browser, Viewer, Inspector, dan timeline magnetic. Semua engine ditulis sendiri tanpa SDK vendor.

## Fitur

**Media & kompatibilitas**
- Codec bawaan macOS lewat AVFoundation: H.264, HEVC, ProRes, dan lainnya (MXF/AVI hanya bila codec-nya didukung macOS).
- Media dapat diimpor lewat dialog atau drag dari Finder ke Browser; video memakai filmstrip multi-frame di timeline dengan skimming saat hover.
- Impor timeline: FCPXML (Final Cut Pro, DaVinci Resolve), Premiere XML (xmeml), EDL. Ekspor FCPXML.
- LUT 3D `.cube`. Relink otomatis (nama sama) dan manual untuk media offline.
- Proxy H.264 1280×720: edit pakai proxy, export selalu memakai file asli. Proxy otomatis untuk media ≥ 4K.
- Keyword, rating (favorit/tolak), catatan, metadata (codec, fps, resolusi, audio), pencarian, smart collection, watch folder.

**Timeline & pemotongan**
- Magnetic storyline, klip connected menempel pada klip induknya, collision avoidance antar lane.
- Gambar diam dapat ditempatkan di timeline, ditumpuk sebagai layer, lalu dipindahkan atau diubah ukurannya langsung di Viewer; Ken Burns pan/zoom dapat diterapkan sebagai keyframe.
- Trim: Ripple, Roll, Slip, Slide. Blade, snapping (tepi klip, playhead, marker), undo/redo 100 langkah.
- Copy/paste klip terpilih ke playhead (`⌘C`/`⌘V`); Blade di playhead (`⌘B`).
- Multicam 2–16 angle disinkronkan otomatis lewat audio, ganti angle saat playback.
- Compound clip (bisa dibuka dan diedit), audition (beberapa take dalam satu slot).
- Source monitor dengan tanda In/Out dan three-point edit (E/W/Q), J-K-L shuttle sampai 8×.
- Marker, beat detection (tempo + posisi beat) dan potong klip sesuai beat.
- Adjustment layer untuk menerapkan grade warna ke beberapa klip di bawahnya dalam satu rentang.
- Versi/snapshot dengan rollback, simpan/buka project `.khcutpro`.

**Efek & compositing**
- Keyframe dengan kurva Bezier untuk opacity, scale, rotasi, posisi, crop, dan volume; kontrol transform langsung di Viewer untuk video, gambar, dan judul.
- Blend mode, crop, mask (elips/persegi), keyer chroma dengan spill suppression, choke, feather.
- Judul dan caption (10 template), termasuk Social Hook, News Banner, End Card, dan gaya subtitle; caption berada di lane khusus, font dan ukurannya dapat diubah di Inspector; impor/ekspor SRT, auto-caption Apple Speech dengan pilihan Bahasa Indonesia.
- Transisi: cross dissolve, dip to black, wipe (4 arah). Look warna 1-klik.
- Stabilizer (Vision) dan point tracker yang menghasilkan keyframe.

**Warna**
- Sistem node serial (bypass, urutkan, salin/tempel grade).
- Color wheels Lift/Gamma/Gain/Offset, temperature/tint, exposure/contrast/saturation, LUT.
- Secondary: qualifier hue/sat/lum dan power window elips.
- Scopes: waveform, parade, vectorscope, histogram.
- Color management: input S-Log3, ARRI LogC3, Rec.2020, HLG; output standar, filmic, atau ACES (perkiraan).

**Audio**
- Waveform di klip, meter level, lane audio A1 Dialog/A2 Musik/A3 Efek dengan fader/mute/solo, fade handle.
- High-pass, EQ 3 band, noise gate, compressor per klip. Auto-ducking musik di bawah dialog. Auto-sync audio eksternal ke video.

**Export**
- ProRes 422, ProRes 4444, H.264 Master/4K/1080p/720p, HEVC, audio M4A. Batch banyak preset sekaligus, rentang In/Out; frame saat ini dapat disimpan ke PNG.
- Penghapusan latar orang sekali klik memakai Vision (lebih berat saat preview/export).

## Pintasan penting

| Aksi | Tombol |
|---|---|
| Play / pause, mundur, maju | `Space`, `J`, `L` (tekan lagi untuk 2×, 4×, 8×), `K` jeda |
| Frame ±1, edit sebelumnya/berikutnya | `←` `→`, `↑` `↓` |
| In / Out, hapus rentang | `I` `O`, `⌥X` |
| Connect / Insert / Append | `Q` `W` `E` |
| Alat Select / Trim / Blade | `A` `T` `B`; mode trim `⌘⌥1…4` |
| Blade di playhead / hapus | `⌘B` / `Delete` |
| Compound / pecah / buka | `⌥G` / `⇧⌘G` / `⌥⌘↓` |
| Ganti angle multicam | `1…9` (hanya audio `⌥1…9`, hanya video `⌃1…9`) |
| Keyframe berikutnya / sebelumnya | `⌥]` / `⌥[` |
| Marker | `M`, lompat `⌥.` / `⌥,` |
| Simpan / buka / versi | `⌘S` / `⌘O` / `⌥⌘S` (daftar `⌥⌘V`) |
| Import / export | `⌘I` / `⌘E`, FCPXML `⇧⌘E` |

Pintasan alat Select, Trim, dan Blade dapat diubah dari **KHCutPro > Settings > Keyboard shortcuts**.

## Batasan yang perlu diketahui

- Tidak ada dukungan Blackmagic RAW, RED RAW, ProRes RAW, DNxHD/HR, AAF, `.mogrt`, dan project native Premiere/Resolve. MXF hanya dapat dibuka bila codec internalnya didukung AVFoundation.
- Belum ada speed ramp per klip; J-K-L hanya mengubah kecepatan playback.
- Planar tracker dan Voice Isolation berbasis AI belum ada; "reduksi derau" memakai gate dan high-pass.
- ACES memakai kurva pendekatan, bukan RRT/ODT resmi. Transformasi input memakai cube 65³.
- Adjustment layer dapat diekspor sebagai video, tetapi tidak dapat direpresentasikan sebagai efek di FCPXML; ekspor FCPXML ditolak selama adjustment layer masih ada.
- Frame rate project tetap 30 fps. Hanya satu level compound yang bisa dibuka di Inspector sekaligus.
- Ekspor FCPXML menyederhanakan compound, multicam, transisi, dan audition menjadi klip biasa.
- Publish langsung ke YouTube belum ada (butuh kredensial OAuth).
- Level meter adalah perkiraan dari waveform sumber dan penguatan klip, bukan pengukuran keluaran mixer.

## Struktur kode

- `Models/TimelineModel.swift`: klip, library, operasi timeline, builder komposisi.
- `KHCutPro/`: engine (animasi, warna, compositor, audio DSP, multicam, tracking, beat, export) dan view tambahan (`*UI.swift`). Folder ini otomatis ikut target app.
- `Services/`: identifikasi media dan parser FCPXML/xmeml/EDL.
- `Views/`, `Sources/App.swift`: antarmuka dan menu.

## Pengujian

`Tools/run_harness.sh` mengompilasi model dan engine (tanpa UI) menjadi satu executable dan menjalankan ratusan pemeriksaan terhadap media sintetis buatan `ffmpeg` (sinkronisasi multicam, render keyframe/keyer/node, codec export, stabilizer, beat, DSP audio, dan lainnya). Satu putaran penuh memakan beberapa menit.
