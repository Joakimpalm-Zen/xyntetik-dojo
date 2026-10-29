#!/bin/sh
# Starts Xyntetik Runner for the pi panes. Finds the runner binary (on PATH, in ~/.xhs/runner, or the
# latest release downloaded and checked against its SHA256SUMS), picks the largest of a short list of
# models that fits this machine (runner --info fit on the first 16 MiB of each, nothing else fetched)
# and serves it on http://127.0.0.1:8080. `--pick` prints the choice and stops.
set -eu
mode=${1:-serve}
home="${XHS_RUNNER_HOME:-$HOME/.xhs/runner}"
release="https://github.com/Joakimpalm-Zen/xyntetik-runner/releases/latest/download"
ctx=16384
# Largest first; the first that fits is served. REPO[:TAG] as runner -hf takes it.
candidates="
Joakimpalm-Zen/Qwen3-Coder-30B-A3B-Instruct-keep120-Q4_K_M-GGUF
Joakimpalm-Zen/Qwen3-30B-A3B-selective-attnQ8_0-expQ4_0-GGUF
ibm-granite/granite-4.2-8b-GGUF:Q4_K_M
bartowski/Qwen_Qwen3-4B-GGUF:Q4_K_M
ibm-granite/granite-4.1-3b-GGUF:Q8_0
"

say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >&2; }

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c -; else shasum -a 256 -c -; fi
}

find_runner() {
    if command -v runner >/dev/null 2>&1; then command -v runner; return; fi
    if [ -x "$home/runner" ]; then say "$home/runner"; return; fi
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) asset=runner-macos-arm64 ;;
        Linux-x86_64) asset=runner-linux-x86_64 ;;
        *) note "No Runner release for $(uname -s) $(uname -m): build it from source and put runner on PATH."; exit 2 ;;
    esac
    mkdir -p "$home"
    note "Downloading Runner ($asset) to $home ..."
    curl -fL -o "$home/$asset" "$release/$asset"
    curl -fsL -o "$home/SHA256SUMS" "$release/SHA256SUMS"
    (cd "$home" && grep " $asset\$" SHA256SUMS | checksum) >&2
    mv "$home/$asset" "$home/runner"
    chmod +x "$home/runner"
    say "$home/runner"
}

# The first .gguf in a Hub repository whose name carries the tag (any file when the tag is empty).
hub_file() {
    curl -fsL "https://huggingface.co/api/models/$1/tree/main" | tr ',' '\n' \
        | grep -o '"path":"[^"]*\.gguf"' | sed 's/"path":"//; s/"$//' | grep -i -- "$2" | head -1
}

pick_model() {
    runner=$1
    mkdir -p "$home/heads"
    for c in $candidates; do
        repo=${c%%:*}
        tag=""
        case $c in *:*) tag=${c#*:} ;; esac
        file=$(hub_file "$repo" "$tag" || true)
        if [ -z "$file" ]; then note "  $c: no file list from the Hub, skipped"; continue; fi
        head="$home/heads/$(say "$repo" | tr / -)-$file"
        if [ ! -s "$head" ]; then
            curl -fsL -r 0-16777215 -o "$head" "https://huggingface.co/$repo/resolve/main/$file" \
                || { rm -f "$head"; note "  $c: could not fetch the file's first 16 MiB, skipped"; continue; }
        fi
        verdict=$("$runner" -m "$head" --info fit -c "$ctx" 2>/dev/null | sed -n 's/^ *verdict *//p' | head -1)
        note "  $c: ${verdict:-no verdict}"
        case $verdict in
            "FITS WITH --kv "*) kv=${verdict#FITS WITH --kv }; say "$c --kv ${kv%% *}"; return ;;
            FITS*) say "$c"; return ;;
        esac
    done
    note "None of the candidate models fits this machine at context $ctx."
    exit 3
}

runner=$(find_runner)
note "Runner $("$runner" --version 2>/dev/null | head -1 || true) at $runner"
note "Which model fits this machine (first 16 MiB of each, largest first):"
choice=$(pick_model "$runner")
say "Serving $choice"
if [ "$mode" = "--pick" ]; then exit 0; fi
# shellcheck disable=SC2086
set -- $choice
model=$1
shift
exec "$runner" -hf "$model" --serve -c "$ctx" "$@"
