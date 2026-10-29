#!/bin/sh
# The model pick: a stub runner says which heads fit, a stub curl stands in for the Hub.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/runner" <<'STUB'
#!/bin/sh
case "$*" in
    --version) echo "runner 0.0 (stub)" ;;
    *30B*) echo "  verdict       PAGES — 12.1 GiB short at ctx 16384" ;;
    *granite-4.2*) echo "  verdict       FITS WITH --kv q8 — 0.4 GiB to spare at ctx 16384" ;;
    *) echo "  verdict       FITS — 3.0 GiB to spare at ctx 16384" ;;
esac
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
chmod +x "$tmp/bin/runner" "$tmp/bin/curl"
got=$(XHS_RUNNER_HOME="$tmp/home" PATH="$tmp/bin:$PATH" sh "$here/runner-start.sh" --pick 2>"$tmp/log")
want="Serving ibm-granite/granite-4.2-8b-GGUF:Q4_K_M --kv q8"
if [ "$got" != "$want" ]; then
    echo "runner-start --pick: got '$got', want '$want'"; cat "$tmp/log"; exit 1
fi
grep -q "Qwen3-Coder-30B.*PAGES" "$tmp/log" || { echo "the 30B verdict is missing from the log"; cat "$tmp/log"; exit 1; }
[ -s "$tmp/home/heads/ibm-granite-granite-4.2-8b-GGUF-granite-4.2-8b-GGUF-Q4_K_M.gguf" ] || { echo "no head file kept"; ls -R "$tmp/home"; exit 1; }
echo "runner-start ok"
