#!/bin/sh
# The model pick: a stub runner says which heads fit, a stub curl stands in for the Hub.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/runner" <<'STUB'
#!/bin/sh
# STUB_AVAIL is the RAM free right now, in GiB. The 30B file is a mixture of experts, Bolt an E-series
# model whose row-gathered table is never resident, Granite-4.2 a dense 8B.
case "$*" in
    --version) echo "runner 0.0 (stub)"; exit 0 ;;
    *30B*) echo "  weights       16.33 GiB"; echo "  hot set       2.02 GiB  (only the routed experts a token actually uses)"
           echo "  verdict       FITS WITH --kv fp4 — a q8 cache is 0.12 GiB over; fp4 halves it again" ;;
    *Bolt*) echo "  weights       5.76 GiB"; echo "  hot set       2.97 GiB  (weights streamed per token)"
            echo "  row-gathered  2.79 GiB  (per-layer token embedding; read by row)"
            echo "  verdict       PAGES — 2.36 GiB over even with the smallest cache. Every token would page from disk." ;;
    *granite-4.2*" -c 16384") echo "  weights       4.90 GiB"; echo "  verdict       PAGES — 0.9 GiB over even with the smallest cache" ;;
    *granite-4.2*" -c 8192") echo "  weights       4.90 GiB"; echo "  verdict       FITS WITH --kv q8 — 0.4 GiB to spare at ctx 8192" ;;
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
out=""; url=""
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; http*) url=$1 ;; esac; shift; done
case $url in
    *api/models/*/tree/main)
        repo=${url#*api/models/}; repo=${repo%/tree/main}; name=$(basename "$repo")
        printf '[{"type":"file","path":"%s-Q2_K.gguf"},{"type":"file","path":"%s-Q4_K_M.gguf"},{"type":"file","path":"%s-Q8_0.gguf"}]' "$name" "$name" "$name" ;;
    *resolve/main/*) printf 'GGUF' > "$out" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$tmp/bin/runner" "$tmp/bin/curl" "$tmp/bin/sysctl"
# An 8 GiB machine with little free: the 30B file and the dense 8B exceed half of RAM; Bolt's resident
# 2.97 GiB does not, so it is served wired in although Runner's free-RAM verdict says it pages now.
got=$(STUB_AVAIL=0.85 XHS_RUNNER_HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh "$here/runner-start.sh" --pick 2>"$tmp/log")
want="Serving nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB -c 16384 --kv q8 --mlock"
if [ "$got" != "$want" ]; then
    echo "runner-start --pick (8 GiB): got '$got', want '$want'"; cat "$tmp/log"; exit 1
fi
grep -q "Qwen3-Coder-30B.*16.33 GiB stay resident.*skipped" "$tmp/log" || { echo "the 30B skip is missing from the log"; cat "$tmp/log"; exit 1; }
grep -q "granite-4.2-8b.*4.90 GiB stay resident.*skipped" "$tmp/log" || { echo "the 8B skip is missing from the log"; cat "$tmp/log"; exit 1; }
[ -s "$tmp/home/heads/nvidia-NVIDIA-Nemotron-3.5-Bolt-E4B-4GB-NVIDIA-Nemotron-3.5-Bolt-E4B-4GB-Q2_K.gguf" ] || { echo "no head file kept"; ls -R "$tmp/home"; exit 1; }
# A 16 GiB machine with 6 GiB free: the dense 8B is within half of RAM and Runner says it fits at 8192.
got=$(STUB_TOTAL_BYTES=17179869184 STUB_AVAIL=6.00 XHS_RUNNER_HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh "$here/runner-start.sh" --pick 2>"$tmp/log")
want="Serving ibm-granite/granite-4.2-8b-GGUF:Q4_K_M -c 8192 --kv q8 --mlock"
if [ "$got" != "$want" ]; then
    echo "runner-start --pick (16 GiB): got '$got', want '$want'"; cat "$tmp/log"; exit 1
fi
echo "runner-start ok"
