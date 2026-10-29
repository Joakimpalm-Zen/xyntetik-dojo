#!/bin/sh
# Records the app's window for N seconds into a GIF for the README: packaging/record-gif.sh NAME SECONDS.
# Uses macOS screencapture for the video and ffmpeg (brew install ffmpeg) for the GIF. Start the app,
# arrange the panes, run this, then do the thing on screen; the GIF lands in packaging/readme/NAME.gif.
set -eu
name=${1:?name}
seconds=${2:-20}
here=$(cd "$(dirname "$0")" && pwd)
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg"; exit 2; }
bounds=$(swift - <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String)?.contains("Xyntetik") == true && (w["kCGWindowLayer"] as? Int) == 0 {
    let b = w["kCGWindowBounds"] as! [String: CGFloat]
    print("\(Int(b["X"]!)),\(Int(b["Y"]!)),\(Int(b["Width"]!)),\(Int(b["Height"]!))")
    break
}
SWIFT
)
[ -n "$bounds" ] || { echo "the app window was not found on screen"; exit 3; }
tmp=$(mktemp -d)
echo "Recording $bounds for $seconds s ..."
screencapture -x -v -V "$seconds" -R "$bounds" "$tmp/$name.mov"
ffmpeg -loglevel error -y -i "$tmp/$name.mov" -vf "fps=8,scale=1200:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" -loop 0 "$here/readme/$name.gif"
rm -rf "$tmp"
ls -l "$here/readme/$name.gif"
