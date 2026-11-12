#!/usr/bin/env bash
#
# Regenerates every image the README uses, from the real example app.
#
#   xcrun simctl boot 'iPhone 17 Pro'
#   tool/screenshots.sh
#
# Steps:
#   1. drives the example through each state and writes full-size PNGs to
#      doc/screenshots/raw/, then resized copies to doc/screenshots/;
#   2. records a second, shorter run and turns it into doc/screenshots/demo.gif.
#
# The recording starts before `flutter drive`, so its first half-minute is the
# Xcode build and the launch. START and DURATION trim that off; check the
# contact sheet the script prints if the timings drift:
#
#   START=36 DURATION=22 tool/screenshots.sh
#
# Needs a booted iOS simulator (xcrun simctl) and ffmpeg.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RAW="$ROOT/doc/screenshots/raw"
OUT="$ROOT/doc/screenshots"
WIDTH="${WIDTH:-540}"
START="${START:-34.6}"
DURATION="${DURATION:-24.4}"

DEVICE="${DEVICE:-$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
devices = [d for v in json.load(sys.stdin)["devices"].values() for d in v]
print(devices[0]["udid"] if devices else "")')}"

if [ -z "$DEVICE" ]; then
  echo "No booted simulator. Try: xcrun simctl boot 'iPhone 17 Pro'" >&2
  exit 1
fi

mkdir -p "$RAW" "$OUT"

# A fixed status bar keeps the recording from dating itself.
xcrun simctl status_bar "$DEVICE" override \
  --time '9:41' --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3

echo "==> Capturing screenshots on $DEVICE"
cd "$ROOT/example"
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart \
  -d "$DEVICE"

echo "==> Resizing to ${WIDTH}px wide"
for file in "$RAW"/*.png; do
  cp "$file" "$OUT/$(basename "$file")"
  sips --resampleWidth "$WIDTH" "$OUT/$(basename "$file")" >/dev/null
done

echo "==> Recording the demo"
VIDEO="$RAW/demo.mov"
rm -f "$VIDEO"
xcrun simctl io "$DEVICE" recordVideo --codec h264 "$VIDEO" &
RECORDER=$!
sleep 3
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/demo_test.dart \
  -d "$DEVICE"
sleep 1
kill -INT "$RECORDER"
wait "$RECORDER" 2>/dev/null || true

echo "==> Converting to GIF (from ${START}s, ${DURATION}s long)"
ffmpeg -v error -y -ss "$START" -t "$DURATION" -i "$VIDEO" \
  -vf "fps=10,scale=320:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=80[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0 "$OUT/demo.gif"

# A strip of the whole recording, to check START and DURATION against.
ffmpeg -v error -y -i "$VIDEO" \
  -vf "fps=1/2.5,scale=130:-1,tile=14x2" -frames:v 1 "$RAW/contact-sheet.png"

echo "==> Done — frames are 2.5s apart in $RAW/contact-sheet.png"
ls -lh "$OUT"
