#!/bin/bash
# Renders every slide-*.html in this folder to PNG, at 1x and 2x.
#
#   ./render.sh            renders all slides
#   ./render.sh slide-2    renders one
#
# Output goes to out/ , kept separate from the sources so the working folder
# stays readable and the finished files are trivial to grab, upload or drag:
#   out/<name>.png   2160x2700  (4:5)
#
# ONE file per slide, not two. A 1x export next to a 2x one is pure duplication:
# the 2x carries strictly more detail, and anything that needs 1080x1350 can be
# downscaled in a second, whereas the reverse is impossible.
#
# --force-device-scale-factor=2 re-renders the page at double resolution rather
# than upscaling a 1x bitmap, so text and vector edges stay genuinely sharp.
# Blowing up a small PNG instead is exactly how the first attempt at this flyer
# ended up an unusable blur.
set -euo pipefail
cd "$(dirname "$0")"

W=1080
H=1350

CHROME="/Users/zenray/Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
if [[ ! -x "$CHROME" ]]; then
    CHROME=$(ls -d "$HOME/Library/Caches/ms-playwright"/chromium-*/chrome-mac-arm64/*.app/Contents/MacOS/* 2>/dev/null | head -1 || true)
fi
if [[ -z "${CHROME:-}" || ! -x "$CHROME" ]]; then
    echo "No headless Chromium found. Install one with: npx playwright install chromium"
    exit 1
fi

mkdir -p out

targets=()
if [[ $# -gt 0 ]]; then
    for a in "$@"; do targets+=("${a%.html}.html"); done
else
    for f in slide-*.html; do targets+=("$f"); done
fi

for html in "${targets[@]}"; do
    [[ -f "$html" ]] || { echo "skip, no such file: $html"; continue; }
    base="${html%.html}"

    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
        --force-device-scale-factor=2 \
        --window-size=$W,$H --screenshot="out/$base.png" \
        "file://$(pwd)/$html" >/dev/null 2>&1

    # Assert the format really is 4:5. A silent wrong-size export is worse than
    # a loud failure: Instagram would crop it and nobody would know why.
    python3 - "$base" $W $H <<'PY'
import sys
from PIL import Image
base, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ok = True
for path, ew, eh in ((f"out/{base}.png", w*2, h*2),):
    got = Image.open(path).size
    flag = "ok" if got == (ew, eh) else f"WRONG, expected {ew}x{eh}"
    if got != (ew, eh): ok = False
    print(f"  {path:28s} {got[0]}x{got[1]}  {flag}")
sys.exit(0 if ok else 1)
PY
done

echo
echo "Done. Files in out/ — $((W*2))x$((H*2)), 4:5."
