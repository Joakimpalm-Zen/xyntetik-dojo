#!/bin/sh
# The model pick against a stub runner, a stub Hub and GitHub, and a stub sysctl for the machine's RAM.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/runner" <<'STUB'
#!/bin/sh
# STUB_AVAIL is the RAM free right now, in GiB. The 30B file is a mixture of experts, Bolt an E-series
# model whose row-gathered table is never resident, Granite a dense 8B, Qwen3-4B small.
case "$*" in
    --version) echo "runner 0.0 (stub)"; exit 0 ;;
    *30B*) echo "  weights       16.33 GiB"; echo "  hot set       2.02 GiB  (only the routed experts a token actually uses)"
           echo "  verdict       FITS WITH --kv fp4 — a q8 cache is 0.12 GiB over; fp4 halves it again" ;;
    *Bolt*) echo "  weights       5.76 GiB"; echo "  hot set       2.97 GiB  (weights streamed per token)"
            echo "  row-gathered  2.79 GiB  (per-layer token embedding; read by row)"
            echo "  verdict       PAGES — 2.36 GiB over even with the smallest cache. Every token would page from disk." ;;
    *granite*" -c 16384") echo "  weights       4.90 GiB"; echo "  verdict       PAGES — 0.9 GiB over even with the smallest cache" ;;
    *granite*" -c 8192") echo "  weights       4.90 GiB"; echo "  verdict       FITS WITH --kv q8 — 0.4 GiB to spare at ctx 8192" ;;
    *merged-Q8_0*) echo "  weights       1.00 GiB"; echo "  verdict       FITS — 4.0 GiB to spare" ;;
    *) echo "  weights       2.40 GiB"; echo "  verdict       FITS — 3.0 GiB to spare" ;;
esac
echo "  available RAM ${STUB_AVAIL:-6.00} GiB right now"
STUB
cat > "$tmp/bin/sysctl" <<'STUB'
#!/bin/sh
echo "${STUB_TOTAL_BYTES:-8589934592}"
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/sh
out=""; url=""; head=0
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; -I|-sI) head=1 ;; http*) url=$1 ;; esac; shift; done
case $url in
    *127.0.0.1:8080/v1/models) [ -n "${STUB_PORT_TAKEN:-}" ] && printf '{"data":[{"id":"kolibri.gguf","owned_by":"llamacpp"}]}' || exit 7 ;;
    *releases/latest) [ $head = 1 ] && printf 'HTTP/2 302\r\nlocation: https://github.com/Joakimpalm-Zen/xyntetik-runner/releases/tag/v9.9.9\r\n\r\n' ;;
    *releases/latest/download/runner-*) cp "$STUB_RUNNER" "$out" ;;
    *releases/latest/download/SHA256SUMS)
        hash=$( (command -v sha256sum >/dev/null && sha256sum "$STUB_RUNNER" || shasum -a 256 "$STUB_RUNNER") | awk '{ print $1 }')
        printf '%s  runner-linux-x86_64\n%s  runner-macos-arm64\n%s *runner-windows-x86_64.exe\n' "$hash" "$hash" "$hash" > "$out" ;;
    *model-tiers.json) cat > "$out" <<'JSON'
{"rows": [
 {"id": "coder-30b", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "Joakimpalm-Zen/Qwen3-Coder-30B-GGUF", "name": "Qwen3-Coder-30B-Q4_K_M.gguf", "bytes": 17000000000}]},
 {"id": "granite-8b", "tier": "tier2", "envelope": {"features": ["text", "tools:granite42"]}, "files": [{"repo": "ibm-granite/granite-4.2-8b-GGUF", "name": "granite-4.2-8b-Q4_K_M.gguf", "bytes": 5261000000}]},
 {"id": "bolt-e4b", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB", "name": "Nemotron-3.5-Bolt-E4B-Q4_K_M.gguf", "bytes": 6180446208}]},
 {"id": "qwen3-4b", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "bartowski/Qwen_Qwen3-4B-GGUF", "name": "Qwen_Qwen3-4B-Q4_K_M.gguf", "bytes": 2500000000}]},
 {"id": "mtp-head", "tier": "tier1", "envelope": {"features": ["mtp"]}, "files": [{"repo": "x/y", "name": "head.gguf", "bytes": 100}]},
 {"id": "split-20b", "tier": "tier1", "envelope": {"features": ["text"]}, "files": [{"repo": "x/Split-GGUF", "name": "Split-00001-of-00002.gguf", "bytes": 6500000000}, {"repo": "x/Split-GGUF", "name": "Split-00002-of-00002.gguf", "bytes": 6500000000}]},
 {"id": "no-bytes", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "x/nb", "name": "nb.gguf"}]},
 {"id": "bad-head", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "x/BadRepo", "name": "Bad.gguf", "bytes": 1000}]},
 {"id": "in-a-folder", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "x/ToolUse", "name": "merged-Q8_0.gguf", "path": "merged/merged-Q8_0.gguf", "bytes": 1100000000}]},
 {"id": "gone-folder", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "x/Gone", "name": "gone.gguf", "path": "old/gone.gguf", "bytes": 1000}]},
 {"id": "coming", "tier": "upcoming", "envelope": {"features": ["text"]}, "files": [{"repo": "x/z", "name": "z.gguf", "bytes": 100}]}
]}
JSON
        ;;
    *resolve/main/Bad*) printf '<html>captive portal</html>' > "$out" ;;
    # A file in a folder of its repository is there by its path; the bare name is a 404, as on the Hub.
    *ToolUse/resolve/main/merged/merged-Q8_0.gguf) printf 'GGUF' > "$out" ;;
    *ToolUse/resolve/main/*|*Gone/resolve/main/*) exit 22 ;;
    # Granite's head is a real GGUF header: trained for a context of 8192, the tensor list cut off after.
    *resolve/main/granite*) python3 -I -c '
import struct, sys
def s(x): b = x.encode(); return struct.pack("<Q", len(b)) + b
out = b"GGUF" + struct.pack("<I", 3) + struct.pack("<QQ", 1, 3)
out += s("general.architecture") + struct.pack("<I", 8) + s("granite")
out += s("general.name") + struct.pack("<I", 8) + s("Granite 4.2 8B")
out += s("granite.context_length") + struct.pack("<I", 4) + struct.pack("<I", 8192)
open(sys.argv[1], "wb").write(out)' "$out" ;;
    *resolve/main/*) printf 'GGUF' > "$out" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$tmp/bin/runner" "$tmp/bin/curl" "$tmp/bin/sysctl"
# A comma-decimal locale must not change the arithmetic.
run() { LANG=sv_SE.UTF-8 LC_ALL=sv_SE.UTF-8 DOJO_RUNNER_HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh "$here/runner-start.sh" --pick 2>"$tmp/log"; }
fail() { echo "$1"; cat "$tmp/log"; [ -f "$tmp/home/fits" ] && cat "$tmp/home/fits"; exit 1; }

# An 8 GiB machine with little free: the 30B file is larger than RAM and never asked; the dense 8B is over
# half of RAM; Bolt (resident 2.97 GiB) and Qwen3-4B fit; Bolt, the largest, is served wired in although
# Runner's free-RAM verdict says it pages now. The head and the adapter rows are not text models.
got=$(STUB_AVAIL=0.85 run)
want="Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock"
[ "$got" = "$want" ] || fail "8 GiB pick: got '$got', want '$want'"
[ "$(cut -f 1 "$tmp/home/fits" | tr '\n' ' ')" = "bolt-e4b qwen3-4b in-a-folder " ] || fail "fits should list bolt-e4b, qwen3-4b, then the file in a folder"
# R10.28: the file in a folder is fetched by its path, its spelling stays REPO:STEM (Runner's -hf matches
# the base name and keeps the folder), and its head is kept under a flat name
grep -q "$(printf 'in-a-folder\tx/ToolUse:merged-Q8_0\t')" "$tmp/home/fits" || fail "the folder file's spelling is REPO:STEM"
[ -s "$tmp/home/heads/x-ToolUse-merged-merged-Q8_0.gguf" ] || fail "the folder file's head is kept under a flat name"
# a fetch that fails is an error line naming what was asked for, not a quiet skip
grep -q "error: gone-folder: could not fetch the first 16 MiB of x/Gone/old/gone.gguf" "$tmp/log" || fail "a failed fetch must be an error line with its path"
grep -q "granite-8b: 4.90 GiB stay resident, more than 0.5 of this machine's RAM" "$tmp/log" || fail "the 8B skip is missing from the log"
grep -q "coder-30b" "$tmp/log" && fail "the 30B file should not be asked about on an 8 GiB machine"
grep -q "latest release is v9.9.9" "$tmp/log" || fail "the latest release tag was not read"

# The picker's choice wins when it fits.
printf 'bartowski/Qwen_Qwen3-4B-GGUF:Qwen_Qwen3-4B-Q4_K_M\n' > "$tmp/home/model"
got=$(STUB_AVAIL=0.85 run)
want="Serving bartowski/Qwen_Qwen3-4B-GGUF:Qwen_Qwen3-4B-Q4_K_M -c 16384 --mlock"
[ "$got" = "$want" ] || fail "chosen model: got '$got', want '$want'"
printf 'nobody/nothing:none\n' > "$tmp/home/model"
got=$(STUB_AVAIL=0.85 run)
[ "$got" = "Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock" ] || fail "a choice that does not fit should fall back"
grep -q "does not fit this machine now" "$tmp/log" || fail "the fallback note is missing"
rm -f "$tmp/home/model"

# A 16 GiB machine with 6 GiB free: the dense 8B is within half of RAM, its head says it was trained for
# 8192, so 8192 is the first context asked, and Runner says it fits there.
got=$(STUB_TOTAL_BYTES=17179869184 STUB_AVAIL=6.00 run)
want="Serving ibm-granite/granite-4.2-8b-GGUF:granite-4.2-8b-Q4_K_M -c 8192 --kv q8 --mlock"
[ "$got" = "$want" ] || fail "16 GiB pick: got '$got', want '$want'"
grep -q "granite-8b: trained for a context of 8192; trying 8192 4096" "$tmp/log" || fail "the trained context was not read from the head"
grep -q "coder-30b: 16.33 GiB stay resident, more than 0.5" "$tmp/log" || fail "the 30B skip is missing on 16 GiB"
grep -q "split-20b: 12.11 GiB in 2 parts, more than 0.5" "$tmp/log" || fail "the split model must be sized by the roster, not its first part"
# The same machine with three quarters of its RAM allowed: the 30B mixture (16.33 GiB over 12 GiB) is still
# out, and a context list of two is tried as given (16384 never asked).
got=$(STUB_TOTAL_BYTES=17179869184 STUB_AVAIL=6.00 DOJO_RUNNER_RAM_SHARE=0.75 DOJO_RUNNER_CONTEXTS="8192 4096" run)
[ "$got" = "Serving ibm-granite/granite-4.2-8b-GGUF:granite-4.2-8b-Q4_K_M -c 8192 --kv q8 --mlock" ] || fail "share and contexts overrides: got '$got'"
grep -q "must fit in 12.00 GiB, 0.75 of this machine's RAM" "$tmp/log" || fail "the share note is missing"
grep -q "granite-8b: trained for a context of 8192; trying 8192 4096" "$tmp/log" || fail "the context list override was not used"
# An 8 GiB machine allowed 0.75: the dense 8B (4.90 GiB) is now in, and the largest resident wins.
got=$(STUB_AVAIL=0.85 DOJO_RUNNER_RAM_SHARE=0.75 run)
[ "$got" = "Serving ibm-granite/granite-4.2-8b-GGUF:granite-4.2-8b-Q4_K_M -c 8192 --kv q8 --mlock" ] || fail "8 GiB at 0.75: got '$got'"
# A share that is not a share is said and replaced by half.
got=$(STUB_AVAIL=0.85 DOJO_RUNNER_RAM_SHARE=all run)
grep -q "DOJO_RUNNER_RAM_SHARE is 'all'" "$tmp/log" || fail "a bad share must be named"
[ "$got" = "Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock" ] || fail "a bad share must fall back to half: got '$got'"
grep -q "no-bytes" "$tmp/log" && fail "a row without sizes must be skipped silently"
# A split model that fits is served at the default context without a verdict; a head that is not GGUF is not kept.
got=$(STUB_TOTAL_BYTES=34359738368 STUB_AVAIL=20.00 run)
[ "$got" = "Serving x/Split-GGUF:Split-00001-of-00002 -c 16384 --kv q8 --mlock" ] || fail "32 GiB pick: got '$got'"
grep -q "error: bad-head: could not fetch the first 16 MiB of x/BadRepo/Bad.gguf" "$tmp/log" || fail "a head that is not GGUF must be an error line"
[ ! -e "$tmp/home/heads/x-BadRepo-Bad.gguf" ] || fail "a head that is not GGUF must not be kept"

# No runner on PATH: the release is downloaded, its checksum line found and matched, the binary used.
mkdir -p "$tmp/nobin"; cp "$tmp/bin/curl" "$tmp/bin/sysctl" "$tmp/nobin/"
got=$(STUB_RUNNER="$tmp/bin/runner" STUB_AVAIL=0.85 DOJO_RUNNER_HOME="$tmp/home" PATH="$tmp/nobin:/usr/bin:/bin" sh "$here/runner-start.sh" --pick 2>"$tmp/log")
[ "$got" = "Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock" ] || fail "download path: got '$got'"
grep -q "Downloading Runner v9.9.9" "$tmp/log" || fail "the release was not downloaded"
grep -q "could not be downloaded" "$tmp/log" && fail "the checksum must match a line of the form 'hash  name'"
[ -x "$tmp/home/runner" ] || fail "the downloaded runner is not in place"
# A stop-gap runner in the Dojo folder is removed, never used.

# A server already on the port: the script steps aside and says who holds it; --pick still picks.
got=$(STUB_PORT_TAKEN=1 STUB_AVAIL=0.85 DOJO_RUNNER_HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh "$here/runner-start.sh" 2>"$tmp/log") && fail "a taken port must stop the script"
grep -q "already answers on 127.0.0.1:8080 (llamacpp, serving kolibri.gguf)" "$tmp/log" || fail "the taken-port note is missing"
got=$(STUB_PORT_TAKEN=1 STUB_AVAIL=0.85 run)
[ "$got" = "Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock" ] || fail "--pick with a taken port: got '$got'"

# Offline: the kept roster copy serves.
mv "$tmp/bin/curl" "$tmp/bin/curl.off"; printf '#!/bin/sh\nexit 6\n' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
got=$(STUB_AVAIL=0.85 run)
[ "$got" = "Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock" ] || fail "offline pick: got '$got'"
grep -q "kept copy" "$tmp/log" || fail "the offline note is missing"
echo "runner-start ok"
