#!/bin/sh
# Starts Xyntetik Runner for the pi panes. Finds the runner binary (on PATH, in ~/.xhs/runner, or the
# latest release downloaded and checked against its SHA256SUMS), picks the largest of a short list of
# models whose resident weights fit in half of this machine's RAM (runner --info fit on the first 16 MiB
# of each, nothing else fetched), and serves it on http://127.0.0.1:8080 with the weights wired into RAM
# (--mlock). Runner's own verdict counts the RAM free right now; when it says the model fits, its context
# and cache setting are used; when it does not, the model is served at context 16384 with a q8 cache and
# the wired weights make the rest of the machine make room. `--pick` prints the choice and stops.
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

# This machine's RAM in GiB.
total_ram_gib() {
    if [ -r /proc/meminfo ]; then awk '/^MemTotal:/ { printf "%.2f", $2 / 1048576 }' /proc/meminfo
    else sysctl -n hw.memsize | awk '{ printf "%.2f", $1 / 1073741824 }'; fi
}

# The weights that stay resident, in GiB, from a fit report: the hot set when the report separates a
# row-gathered table (Gemma E-series: that table is read by row and never resident), else the whole file.
resident_gib() {
    if printf '%s\n' "$1" | grep -q '^ *row-gathered'; then
        printf '%s\n' "$1" | awk '/^ *hot set/ { print ($3 == "GiB") ? $2 : 0; exit }'
    else
        printf '%s\n' "$1" | awk '/^ *weights/ { print ($3 == "GiB") ? $2 : 0; exit }'
    fi
}

pick_model() {
    runner=$1
    half=$(total_ram_gib | awk '{ printf "%.2f", $1 / 2 }')
    note "Half of this machine's RAM is $half GiB; a model's resident weights must fit in that."
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
        report=$("$runner" -m "$head" --info fit -c 16384 2>/dev/null || true)
        resident=$(resident_gib "$report")
        if [ -z "$resident" ] || ! awk -v r="$resident" -v h="$half" 'BEGIN { exit !(r <= h) }'; then
            note "  $c: ${resident:-?} GiB stay resident, more than half of this machine's RAM; skipped"
            continue
        fi
        for ctx in $contexts; do
            [ "$ctx" = 16384 ] || report=$("$runner" -m "$head" --info fit -c "$ctx" 2>/dev/null || true)
            verdict=$(printf '%s\n' "$report" | sed -n 's/^ *verdict *//p' | head -1)
            note "  $c at context $ctx: ${verdict:-no verdict}"
            case $verdict in
                "FITS WITH --kv "*) kv=${verdict#FITS WITH --kv }; say "$c -c $ctx --kv ${kv%% *} --mlock"; return ;;
                FITS*) say "$c -c $ctx --mlock"; return ;;
            esac
        done
        note "  $c: $resident GiB stay resident, within half of this machine's RAM; wired in, the rest makes room"
        say "$c -c 16384 --kv q8 --mlock"
        return
    done
    note "No candidate model keeps its resident weights within half of this machine's RAM."
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
