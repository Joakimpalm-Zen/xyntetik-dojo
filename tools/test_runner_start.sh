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
    *releases/latest) [ $head = 1 ] && printf 'HTTP/2 302\r\nlocation: https://github.com/Joakimpalm-Zen/xyntetik-runner/releases/tag/v9.9.9\r\n\r\n' ;;
    *model-tiers.json) cat > "$out" <<'JSON'
{"rows": [
 {"id": "coder-30b", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "Joakimpalm-Zen/Qwen3-Coder-30B-GGUF", "name": "Qwen3-Coder-30B-Q4_K_M.gguf", "bytes": 17000000000}]},
 {"id": "granite-8b", "tier": "tier2", "envelope": {"features": ["text", "tools:granite42"]}, "files": [{"repo": "ibm-granite/granite-4.2-8b-GGUF", "name": "granite-4.2-8b-Q4_K_M.gguf", "bytes": 5261000000}]},
 {"id": "bolt-e4b", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB", "name": "Nemotron-3.5-Bolt-E4B-Q4_K_M.gguf", "bytes": 6180446208}]},
 {"id": "qwen3-4b", "tier": "tier2", "envelope": {"features": ["text"]}, "files": [{"repo": "bartowski/Qwen_Qwen3-4B-GGUF", "name": "Qwen_Qwen3-4B-Q4_K_M.gguf", "bytes": 2500000000}]},
 {"id": "mtp-head", "tier": "tier1", "envelope": {"features": ["mtp"]}, "files": [{"repo": "x/y", "name": "head.gguf", "bytes": 100}]},
 {"id": "coming", "tier": "upcoming", "envelope": {"features": ["text"]}, "files": [{"repo": "x/z", "name": "z.gguf", "bytes": 100}]}
]}
JSON
        ;;
    *resolve/main/*) printf 'GGUF' > "$out" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$tmp/bin/runner" "$tmp/bin/curl" "$tmp/bin/sysctl"
run() { XHS_RUNNER_HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh "$here/runner-start.sh" --pick 2>"$tmp/log"; }
fail() { echo "$1"; cat "$tmp/log"; [ -f "$tmp/home/fits" ] && cat "$tmp/home/fits"; exit 1; }

# An 8 GiB machine with little free: the 30B file is larger than RAM and never asked; the dense 8B is over
# half of RAM; Bolt (resident 2.97 GiB) and Qwen3-4B fit; Bolt, the largest, is served wired in although
# Runner's free-RAM verdict says it pages now. The head and the adapter rows are not text models.
got=$(STUB_AVAIL=0.85 run)
want="Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock"
[ "$got" = "$want" ] || fail "8 GiB pick: got '$got', want '$want'"
[ "$(cut -f 1 "$tmp/home/fits" | tr '\n' ' ')" = "bolt-e4b qwen3-4b " ] || fail "fits should list bolt-e4b then qwen3-4b"
grep -q "granite-8b: 4.90 GiB stay resident, more than half" "$tmp/log" || fail "the 8B skip is missing from the log"
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

# A 16 GiB machine with 6 GiB free: the dense 8B is within half of RAM and Runner says it fits at 8192.
got=$(STUB_TOTAL_BYTES=17179869184 STUB_AVAIL=6.00 run)
want="Serving ibm-granite/granite-4.2-8b-GGUF:granite-4.2-8b-Q4_K_M -c 8192 --kv q8 --mlock"
[ "$got" = "$want" ] || fail "16 GiB pick: got '$got', want '$want'"
grep -q "coder-30b: 16.33 GiB stay resident, more than half" "$tmp/log" || fail "the 30B skip is missing on 16 GiB"

# Offline: the kept roster copy serves.
mv "$tmp/bin/curl" "$tmp/bin/curl.off"; printf '#!/bin/sh\nexit 6\n' > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
got=$(STUB_AVAIL=0.85 run)
[ "$got" = "Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB:Nemotron-3.5-Bolt-E4B-Q4_K_M -c 16384 --kv q8 --mlock" ] || fail "offline pick: got '$got'"
grep -q "kept copy" "$tmp/log" || fail "the offline note is missing"
echo "runner-start ok"
