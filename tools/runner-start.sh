#!/bin/sh
# Starts Xyntetik Runner for the pi panes. Finds the runner binary (on PATH, in ~/.xhs/runner, or the
# latest release downloaded and checked against its SHA256SUMS), picks the largest of a short list of
# models that fits this machine (runner --info fit on the first 16 MiB of each, nothing else fetched),
# at the largest of three context sizes it fits with, and serves it on http://127.0.0.1:8080. A model whose
# whole file fits in the RAM free right now wins over one that fits by its hot set alone (a mixture of
# experts whose file exceeds RAM, which Runner rates usable); that one is the fallback.
# `--pick` prints the choice and stops.
set -eu
mode=${1:-serve}
home="${XHS_RUNNER_HOME:-$HOME/.xhs/runner}"
release="https://github.com/Joakimpalm-Zen/xyntetik-runner/releases/latest/download"
# Context sizes to try for each model, largest first.
contexts="16384 8192 4096"
# Largest first; the first that fits at any of the contexts is served. REPO[:TAG] as runner -hf takes it.
candidates="
Joakimpalm-Zen/Qwen3-Coder-30B-A3B-Instruct-keep120-Q4_K_M-GGUF
Joakimpalm-Zen/Qwen3-30B-A3B-selective-attnQ8_0-expQ4_0-GGUF
ibm-granite/granite-4.2-8b-GGUF:Q4_K_M
nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-4GB
bartowski/Qwen_Qwen3-4B-GGUF:Q4_K_M
ibm-granite/granite-4.1-3b-GGUF:Q8_0
ibm-granite/granite-4.1-3b-GGUF:Q4_K_M
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

# Does the whole file (the weights line) fit in the RAM available right now? Both in GiB; MiB counts as fitting.
whole_file_fits() {
    weights=$(printf '%s\n' "$1" | awk '/^ *weights/ { print ($3 == "GiB") ? $2 : 0 }')
    avail=$(printf '%s\n' "$1" | awk '/^ *available RAM/ { print ($4 == "GiB") ? $3 : 0 }')
    [ -n "$weights" ] && [ -n "$avail" ] && awk -v w="$weights" -v a="$avail" 'BEGIN { exit !(w <= a) }'
}

pick_model() {
    runner=$1
    fallback=""
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
        for ctx in $contexts; do
            report=$("$runner" -m "$head" --info fit -c "$ctx" 2>/dev/null || true)
            verdict=$(printf '%s\n' "$report" | sed -n 's/^ *verdict *//p' | head -1)
            note "  $c at context $ctx: ${verdict:-no verdict}"
            choice=""
            case $verdict in
                "FITS WITH --kv "*) kv=${verdict#FITS WITH --kv }; choice="$c -c $ctx --kv ${kv%% *}" ;;
                FITS*) choice="$c -c $ctx" ;;
            esac
            [ -n "$choice" ] || continue
            if whole_file_fits "$report"; then say "$choice"; return; fi
            note "    the whole file does not fit in the RAM free right now; kept as the fallback"
            [ -n "$fallback" ] || fallback=$choice
            break
        done
    done
    if [ -n "$fallback" ]; then
        note "No model's whole file fits in the RAM free right now (quit what you are not using and try again); serving the one Runner rates usable by its hot set."
        say "$fallback"
        return
    fi
    note "None of the candidate models fits this machine, even at context 4096."
    exit 3
}

runner=$(find_runner)
note "Runner $("$runner" --version 2>/dev/null | head -1 || true) at $runner"
note "Which model fits this machine (first 16 MiB of each, largest model and context first):"
choice=$(pick_model "$runner")
say "Serving $choice"
if [ "$mode" = "--pick" ]; then exit 0; fi
# shellcheck disable=SC2086
set -- $choice
model=$1
shift
exec "$runner" -hf "$model" --serve "$@"
