#!/bin/bash
# Membuat media sintetis untuk harness uji (butuh ffmpeg). Pemakaian: Tools/make_fixtures.sh <folder-tujuan>
set -e
OUT="${1:-${TMPDIR:-/tmp}/khcutpro-fixtures}"
mkdir -p "$OUT" && cd "$OUT"
F="ffmpeg -y -loglevel error"

# Audio sumber untuk uji sinkronisasi multicam / auto-sync
$F -f lavfi -i "aevalsrc='random(0)*(sin(2*PI*0.37*t)+sin(2*PI*0.91*t)+0.8*sin(2*PI*0.11*t*t))*0.25':s=44100:d=40" base.wav
$F -f lavfi -i testsrc=size=320x180:rate=30:duration=20 -ss 0   -t 20 -i base.wav -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest camA.mp4
$F -f lavfi -i testsrc2=size=320x180:rate=30:duration=20 -ss 3.5 -t 20 -i base.wav -af "volume=0.4,highpass=f=200" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest camB.mp4
$F -f lavfi -i smptebars=size=320x180:rate=30:duration=20 -ss 5 -t 20 -i base.wav -af "volume=2" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest camC.mp4
$F -ss 5 -t 20 -i base.wav -af volume=0.7 ext.wav

# Klip pendek umum
$F -f lavfi -i testsrc=duration=4:size=640x360:rate=30 -f lavfi -i sine=frequency=440:duration=4 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest a.mp4
$F -f lavfi -i testsrc2=duration=3:size=1280x720:rate=30 -c:v libx264 -pix_fmt yuv420p b.mp4
$F -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=4 -f lavfi -i "sine=frequency=500:duration=4" -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest big.mp4

# Audio: dialog (burst 2–5 s dan 7–8 s), musik, efek, nada uji DSP
$F -f lavfi -i testsrc=size=320x180:rate=30:duration=10 -f lavfi -i "aevalsrc='random(0)*0.5*((gte(t,2)*lte(t,5))+(gte(t,7)*lte(t,8)))':s=44100:d=10" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest dialog.mp4
$F -f lavfi -i "sine=frequency=440:duration=12" -af volume=0.4 music_bed.wav
$F -f lavfi -i "sine=frequency=900:duration=1.5" -af volume=0.5 fx_whoosh.wav
$F -f lavfi -i "sine=frequency=1000:duration=4" -af volume=1.6 tone1k.wav
$F -f lavfi -i "sine=frequency=100:duration=4" -af volume=2.4 tone100.wav
$F -f lavfi -i "anoisesrc=color=white:amplitude=0.003:duration=4:sample_rate=44100" noise_low.wav
$F -f lavfi -i "sine=frequency=1000:duration=4" -af volume=6.4 loud1k.wav

# Klik metronom 120 dan 90 BPM
$F -f lavfi -i "aevalsrc='sin(2*PI*1000*t)*exp(-40*mod(t,0.5))*0.8':s=44100:d=20" click120.wav
$F -f lavfi -i "aevalsrc='sin(2*PI*800*t)*exp(-40*mod(t+0.13,0.6667))*0.8':s=44100:d=20" click90.wav

# Stabilizer: tekstur acak yang digoyang dengan lintasan yang diketahui; tracker: kotak putih bergerak
$F -f lavfi -i "color=c=gray:s=720x405:d=1" -vf "noise=alls=100:allf=t,noise=alls=80:allf=t,gblur=sigma=1.2" -frames:v 1 texture.png
$F -loop 1 -framerate 30 -t 8 -i texture.png -vf "crop=w=640:h=360:x='40+14*sin(2*PI*t*1.7)+6*sin(2*PI*t*3.1)':y='22+9*sin(2*PI*t*1.3)+4*sin(2*PI*t*2.9)'" -c:v libx264 -crf 14 -pix_fmt yuv420p shaky.mp4
$F -f lavfi -i "color=c=black:s=320x180:r=30:d=6" -f lavfi -i "color=c=white:s=28x28:r=30:d=6" -filter_complex "[0][1]overlay=x='20+t*45':y='70+25*sin(t*2)'" -c:v libx264 -pix_fmt yuv420p mover.mp4
echo "Fixture siap di: $OUT"
