#!/bin/sh
# Starts Xyntetik Runner for the pi panes. Nothing about Runner versions or models is written here:
#  - the binary is `runner` on PATH (yours), else ~/.xhs/runner/runner, downloaded from the latest release
#    and replaced when a newer release exists (checked against SHA256SUMS);
#  - the models are Runner's own roster, docs/model-tiers.json in its repository (Tier 1 and Tier 2 text
#    models), fetched on every start and kept as a copy for when the network is away.
# Every roster file no larger than this machine's RAM is asked about with `runner --info fit` on its first
# 16 MiB. A model fits when the weights that stay resident (the hot set for a Gemma E-series model, whose
# row-gathered token table is never resident; the whole file otherwise) are within half of the RAM. All
# that fit are written to ~/.xhs/runner/fits, largest resident weights first; the one named in ~/.xhs/runner/model (the
# picker writes it) or else the first is served, wired into RAM (--mlock): at Runner's context and cache
# when its free-RAM verdict says FITS, else at context 16384 with a q8 cache. `--pick` prints the choice
# and stops.
set -eu
mode=${1:-serve}
home="${XHS_RUNNER_HOME:-$HOME/.xhs/runner}"
release="https://github.com/Joakimpalm-Zen/xyntetik-runner/releases/latest"
roster_url="https://raw.githubusercontent.com/Joakimpalm-Zen/xyntetik-runner/main/docs/model-tiers.json"
contexts="16384 8192 4096"
mkdir -p "$home/heads"

say() { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >&2; }

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c -; else shasum -a 256 -c -; fi
}

# The tag of the latest release, from where GitHub's "latest" link points; empty when offline.
latest_tag() {
    curl -sI "$release" 2>/dev/null | awk 'tolower($1) == "location:" { print $2 }' | sed 's|.*/tag/||; s/[[:space:]]*$//'
}

download_runner() {
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) asset=runner-macos-arm64 ;;
        Linux-x86_64) asset=runner-linux-x86_64 ;;
        *) note "No Runner release for $(uname -s) $(uname -m): build it from source and put runner on PATH."; exit 2 ;;
    esac
    note "Downloading Runner $1 ($asset) to $home ..."
    curl -fL -o "$home/$asset" "$release/download/$asset"
    curl -fsL -o "$home/SHA256SUMS" "$release/download/SHA256SUMS"
    (cd "$home" && grep " $asset\$" SHA256SUMS | checksum) >&2
    mv "$home/$asset" "$home/runner"
    chmod +x "$home/runner"
}

find_runner() {
    latest=$(latest_tag || true)
    if command -v runner >/dev/null 2>&1; then
        bin=$(command -v runner)
        note "Runner $("$bin" --version 2>/dev/null | head -1 || true) at $bin (yours; the latest release is ${latest:-unknown})"
        say "$bin"
        return
    fi
    if [ -x "$home/runner" ]; then
        have=$("$home/runner" --version 2>/dev/null | awk '{ print $2 }' || true)
        if [ -n "$latest" ] && [ "v$have" != "$latest" ] && [ "$have" != "$latest" ]; then
            note "Runner $have is here; $latest is the latest release."
            download_runner "$latest"
        fi
    else
        download_runner "${latest:-latest}"
    fi
    note "Runner $("$home/runner" --version 2>/dev/null | head -1 || true) at $home/runner"
    say "$home/runner"
}

# This machine's RAM in bytes.
total_ram_bytes() {
    if [ -r /proc/meminfo ]; then awk '/^MemTotal:/ { printf "%.0f", $2 * 1024 }' /proc/meminfo
    else sysctl -n hw.memsize; fi
}

# Runner's roster, fetched fresh when the network allows, else the kept copy.
roster_file() {
    if curl -fsL -o "$home/model-tiers.json.new" "$roster_url" 2>/dev/null; then
        mv "$home/model-tiers.json.new" "$home/model-tiers.json"
    else
        rm -f "$home/model-tiers.json.new"
        [ -s "$home/model-tiers.json" ] || { note "Runner's model roster could not be fetched and no copy is kept."; exit 4; }
        note "Using the kept copy of Runner's model roster; the network did not answer."
    fi
    say "$home/model-tiers.json"
}

# One line per candidate: id, repo, first file, total bytes. Tier 1 and 2 text models, each no larger
# than this machine's RAM, largest first.
candidates() {
    python3 -I - "$1" "$2" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
ram = int(sys.argv[2])
out = []
for r in rows:
    if r.get("tier") not in ("tier1", "tier2") or not r.get("files"):
        continue
    if "text" not in ((r.get("envelope") or {}).get("features") or []):
        continue
    total = sum(f["bytes"] for f in r["files"])
    if total > ram:
        continue
    out.append((total, r["id"], r["files"][0]["repo"], r["files"][0]["name"]))
for total, rid, repo, name in sorted(out, reverse=True):
    print(rid, repo, name, total)
PY
}

# The weights that stay resident, in GiB, from a fit report: the hot set when the report separates a
# row-gathered table (Gemma E-series: that table is read by row and never resident), else the whole file.
resident_gib() {
    if printf '%s\n' "$1" | grep -q '^ *row-gathered'; then
        printf '%s\n' "$1" | awk '/^ *hot set/ { print ($4 == "GiB") ? $3 : 0; exit }'
    else
        printf '%s\n' "$1" | awk '/^ *weights/ { print ($3 == "GiB") ? $2 : 0; exit }'
    fi
}

# Writes $home/fits: "id<TAB>REPO:STEM<TAB>flags<TAB>resident GiB" for every model that fits, largest first.
list_fits() {
    runner=$1
    ram=$(total_ram_bytes)
    half=$(awk -v b="$ram" 'BEGIN { printf "%.2f", b / 2 / 1073741824 }')
    note "Half of this machine's RAM is $half GiB; a model's resident weights must fit in that."
    : > "$home/fits.new"
    candidates "$(roster_file)" "$ram" | while read -r id repo file bytes; do
        head="$home/heads/$(say "$repo" | tr / -)-$file"
        if [ ! -s "$head" ]; then
            curl -fsL -r 0-16777215 -o "$head" "https://huggingface.co/$repo/resolve/main/$file" \
                || { rm -f "$head"; note "  $id: could not fetch the file's first 16 MiB, skipped"; continue; }
        fi
        report=$("$runner" -m "$head" --info fit -c 16384 2>/dev/null || true)
        resident=$(resident_gib "$report")
        if [ -z "$resident" ] || ! awk -v r="$resident" -v h="$half" 'BEGIN { exit !(r <= h) }'; then
            note "  $id: ${resident:-?} GiB stay resident, more than half of this machine's RAM"
            continue
        fi
        spelling="$repo:${file%.gguf}"
        flags=""
        for ctx in $contexts; do
            [ "$ctx" = 16384 ] || report=$("$runner" -m "$head" --info fit -c "$ctx" 2>/dev/null || true)
            verdict=$(printf '%s\n' "$report" | sed -n 's/^ *verdict *//p' | head -1)
            case $verdict in
                "FITS WITH --kv "*) kv=${verdict#FITS WITH --kv }; flags="-c $ctx --kv ${kv%% *}"; break ;;
                FITS*) flags="-c $ctx"; break ;;
            esac
        done
        if [ -n "$flags" ]; then
            note "  $id: fits, $resident GiB resident; Runner says $verdict"
        else
            flags="-c 16384 --kv q8"
            note "  $id: fits, $resident GiB resident, wired in; Runner's free-RAM verdict said it pages right now"
        fi
        printf '%s\t%s\t%s\t%s\n' "$id" "$spelling" "$flags --mlock" "$resident" >> "$home/fits.new"
    done
    # Largest resident weights first: what loads is the measure, not the file.
    sort -t "$(printf '\t')" -k4,4nr "$home/fits.new" > "$home/fits"
    rm -f "$home/fits.new"
}

runner=$(find_runner)
list_fits "$runner"
[ -s "$home/fits" ] || { note "No roster model keeps its resident weights within half of this machine's RAM."; exit 3; }
chosen=""
if [ -s "$home/model" ]; then
    want=$(head -1 "$home/model")
    chosen=$(awk -F '\t' -v w="$want" '$2 == w { print; exit }' "$home/fits")
    [ -n "$chosen" ] || note "The chosen model ($want) does not fit this machine now; serving the largest that does."
fi
[ -n "$chosen" ] || chosen=$(head -1 "$home/fits")
spelling=$(printf '%s\n' "$chosen" | cut -f 2)
flags=$(printf '%s\n' "$chosen" | cut -f 3)
say "Serving $spelling $flags"
if [ "$mode" = "--pick" ]; then exit 0; fi
# shellcheck disable=SC2086
exec "$runner" -hf "$spelling" --serve $flags
