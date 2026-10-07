#!/bin/bash
# Menjalankan harness regresi: mengompilasi model dan engine (tanpa UI) ke satu executable lalu menjalankannya.
# Pemakaian: Tools/run_harness.sh [folder-fixture]     (butuh ffmpeg dan Xcode command line tools)
# Satu putaran penuh memakan beberapa menit karena banyak export video.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="${1:-${TMPDIR:-/tmp}/khcutpro-fixtures}"
BIN="${TMPDIR:-/tmp}/khcutpro-harness"
[ -f "$FIX/camA.mp4" ] || "$ROOT/Tools/make_fixtures.sh" "$FIX"
cd "$ROOT"
swiftc -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability -O -o "$BIN" \
  Tools/harness/main.swift Models/*.swift Services/*.swift $(ls KHCutPro/*.swift | grep -v -e 'UI.swift' -e DemoProject.swift)
"$BIN" "$FIX"
