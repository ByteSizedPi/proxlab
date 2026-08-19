#!/usr/bin/env bash
#
# Print one row per benchmark run, so the matrix reads as a table.
#
#     scripts/jellyfin-stream-compare.sh
#     scripts/jellyfin-stream-compare.sh tv-4k phone-4k
#
# Reads the .tsv sample files written by jellyfin-stream-bench.sh. Pass labels
# to pick runs, or pass nothing to take every run in docs/streaming/.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/streaming"
WARMUP="${WARMUP:-20}"

if [[ $# -gt 0 ]]; then
    FILES=()
    for l in "$@"; do FILES+=("$OUT_DIR/$l.tsv"); done
else
    mapfile -t FILES < <(ls -1 "$OUT_DIR"/*.tsv 2>/dev/null)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "no runs found in $OUT_DIR" >&2
    exit 1
fi

{
printf 'run\tmethod\tkind\tcpu_mean\tcpu_peak\tenc_fps\tout_mbit\ttx_mbit\tstalls\n'
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "missing: $f" >&2; continue; }
    label=$(basename "$f" .tsv)
    awk -F'\t' -v label="$label" -v warm="$WARMUP" '
    NR == 1 { next }
    {
        method[$3]++
        if (NR > 2 && $2 >= warm && $5 == "false" && $4 == prev_pos) stalls++
        if ($15 != "") vdir[$15]++
        if ($16 != "") adir[$16]++
        prev_pos = $4
        # Only take byte counters from rows that actually carry one. The first
        # row or two can be empty, because the remote sampler has not emitted a
        # line yet. An empty value used as the starting count silently becomes
        # zero, which reports the whole lifetime traffic of the container as if
        # it happened during this run.
        # Count bytes only across samples where playback is actually running.
        # Paused samples carry almost no traffic and would drag the mean down.
        if ($14 != "" && $5 == "false") {
            if (first_tx == "") { first_ts = $1; first_tx = $14 }
            last_ts = $1; last_tx = $14
        }
        if ($2 >= warm) {
            if ($6 != "") { fps += $6; fpsn++ }
            if ($7 != "") { br += $7; brn++ }
            if ($11 != "") { cpu += $11; cpun++; if ($11 > cpumax) cpumax = $11 }
        }
    }
    END {
        best = ""; for (k in method) if (best == "" || method[k] > method[best]) best = k
        kind = "-"
        if (best == "Transcode") {
            if (length(vdir) == 0) kind = "unknown"
            else {
                vd = ("true" in vdir) && !("false" in vdir)
                ad = ("true" in adir) && !("false" in adir)
                kind = vd ? (ad ? "remux" : "audio-only") : "re-encode"
            }
        } else if (best != "") kind = "direct"
        printf "%s\t%s\t%s\t", label, best, kind
        if (cpun) printf "%.1f%%\t%.1f%%\t", cpu/cpun, cpumax; else printf "-\t-\t"
        if (fpsn) printf "%.1f\t", fps/fpsn; else printf "-\t"
        if (brn) printf "%.1f\t", br/brn/1000000; else printf "-\t"
        if (first_tx != "" && last_ts > first_ts && last_tx+0 > first_tx+0)
            printf "%.1f\t", (last_tx-first_tx)*8/(last_ts-first_ts)/1000000
        else printf "-\t"
        printf "%d\n", stalls+0
    }' "$f"
done
} | column -t -s $'\t'
