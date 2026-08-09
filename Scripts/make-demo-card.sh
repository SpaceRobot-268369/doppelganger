#!/bin/bash
# Generates a SYNTHETIC demo "camera card" for exercising doppelganger.
# Never point doppelganger demos at real camera cards or real footage
# (AGENTS.md Principle 3) — this script exists so you never have to.
#
# Usage:
#   make-demo-card.sh [output-dir] [total-size-mb]
#
#   output-dir     default: ~/Desktop/DemoCard
#   total-size-mb  default: 500 (approximate, split across clips)
#
# Demo ideas:
#   - Happy path: offload the card to two destination folders; both end green
#     with a JSON manifest and a Markdown report on each.
#   - Collision failure: run the same transfer twice into the same
#     destination — the second run fails loudly with name collisions and the
#     existing files are untouched.
#   - Full-disk failure: use a tiny disk image as a destination:
#       hdiutil create -size 100m -fs APFS -volname TinyDest /tmp/tiny.dmg
#       hdiutil attach /tmp/tiny.dmg
set -euo pipefail

OUT="${1:-$HOME/Desktop/DemoCard}"
TOTAL_MB="${2:-500}"

if [[ -e "$OUT" ]]; then
  echo "error: $OUT already exists — remove it first or pick another path" >&2
  exit 1
fi

CLIPS=8
CLIP_MB=$(( TOTAL_MB / CLIPS ))
[[ $CLIP_MB -lt 1 ]] && CLIP_MB=1

mkdir -p "$OUT/DCIM/100DEMO" "$OUT/PRIVATE/M4ROOT/CLIP" "$OUT/MISC"

echo "Generating ~${TOTAL_MB} MB of synthetic footage in $OUT …"
for i in $(seq 1 $CLIPS); do
  n=$(printf '%04d' "$i")
  if (( i % 2 )); then
    target="$OUT/DCIM/100DEMO/DEMO_${n}.MP4"
  else
    target="$OUT/PRIVATE/M4ROOT/CLIP/C${n}.MXF"
  fi
  dd if=/dev/urandom of="$target" bs=1m count="$CLIP_MB" status=none
  echo "  $target (${CLIP_MB} MB)"
done

# Small sidecar files, like a real card
for i in 1 3 5 7; do
  n=$(printf '%04d' "$i")
  echo "<xml demo sidecar for DEMO_${n}/>" > "$OUT/DCIM/100DEMO/DEMO_${n}M01.XML"
done
echo "synthetic demo card generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/MISC/README.txt"

echo
echo "Done. This is SYNTHETIC media — safe to offload, corrupt, or delete."
echo "Card root: $OUT"
