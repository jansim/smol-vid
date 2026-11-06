#!/bin/sh
# Writes a short test video (moving test patterns, a tone, a title and two chapters) for smoke tests.
# usage: scripts/make-test-video.sh <output.mov>
set -eu
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
printf ';FFMETADATA1\ntitle=smol-vid test video\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=4000\ntitle=Two\n' > "$dir/meta.txt"
ffmpeg -nostdin -v error -y \
    -f lavfi -i testsrc2=size=1920x1080:rate=60:duration=4 \
    -f lavfi -i sine=frequency=440:duration=4 \
    -f ffmetadata -i "$dir/meta.txt" -map 0:v -map 1:a -map_metadata 2 -map_chapters 2 \
    -c:v libx264 -crf 12 -pix_fmt yuv420p -c:a aac -b:a 256k "$1"
