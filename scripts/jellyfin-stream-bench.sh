#!/usr/bin/env bash
#
# Measure what one Jellyfin playback session costs the server and the network.
#
# Run it once per cell of the test matrix. Pass a label:
#
#     scripts/jellyfin-stream-bench.sh tv-4k
#     scripts/jellyfin-stream-bench.sh phone-4k
#
# Each run writes three files under docs/streaming/:
#
#     <label>.txt           the report a human reads
#     <label>.tsv           one sample row every ~2 s, for plotting
#     <label>.session.json  the raw Jellyfin session record, as evidence
#
# The script does not start playback. You start playback on the TV or the
# phone, the script waits for the session to appear, locks onto it, and
# samples until the run duration is up.
#
# WHAT IT MEASURES AND WHY
#
# A Jellyfin stream is cheap or expensive depending on one thing: PlayMethod.
#
#   DirectPlay    Jellyfin sends the file. Server CPU near zero. The network
#                 carries the full source bitrate.
#   DirectStream  Jellyfin repackages the container, video untouched. Cheap.
#   Transcode     Jellyfin decodes and re-encodes. pve-prod has no /dev/dri
#                 passthrough (see stacks/media/jellyfin/compose.yaml), so
#                 this is libx264 on the R720 Xeons. Expensive.
#
# The client decides which one happens, from its own decoder support and its
# quality setting. So the numbers that matter per run are: which method was
# chosen, why (TranscodeReasons), what the encode cost, and whether playback
# actually kept up.
#
# Encode framerate is the health metric for a transcode. If the transcoder
# produces fewer frames per second than the source framerate, it is losing to
# realtime and the client will stall. The report calls this the realtime
# factor.
#
# Uses only tools already present: curl, jq, ssh, awk. Nothing gets installed.

set -uo pipefail

DURATION=180   # seconds of playback to sample
WARMUP=20      # leading seconds excluded from the averages (startup burst)
DEVICE_FILTER=""
REPORT_ONLY=0
FFMPEG_ARGS=""

usage() {
    cat >&2 <<'USAGE'
usage: jellyfin-stream-bench.sh [-d seconds] [-w seconds] [-D device] [-r] <label>

  -d  sample this many seconds of playback   (default 180)
  -w  exclude this many leading seconds      (default 20)
  -D  only lock onto a session whose device name contains this string
  -r  rebuild the report from an already-captured run, capture nothing
USAGE
    exit 1
}

while getopts ":d:w:D:r" opt; do
    case "$opt" in
        d) DURATION="$OPTARG" ;;
        w) WARMUP="$OPTARG" ;;
        D) DEVICE_FILTER="$OPTARG" ;;
        r) REPORT_ONLY=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

LABEL="${1:-}"
[[ -z "$LABEL" ]] && usage

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/streaming"
mkdir -p "$OUT_DIR"

# The API key is a secret, so it never lives in the repo. `*.local.env` is
# already gitignored (see .gitignore).
ENV_FILE="$REPO_ROOT/scripts/jellyfin-bench.local.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

JELLYFIN_URL="${JELLYFIN_URL:-https://jellyfin.admin.jjventer.co.za}"
SSH_HOST="${SSH_HOST:-pve-prod}"
CONTAINER="${CONTAINER:-jellyfin}"

TSV="$OUT_DIR/$LABEL.tsv"
TXT="$OUT_DIR/$LABEL.txt"
JSON="$OUT_DIR/$LABEL.session.json"

# -------------------------------------------------------------------- report
#
# Kept as a function so `-r <label>` can rebuild a report from a .tsv that
# was already captured. Useful when the report format changes and the old
# runs should be re-rendered rather than re-run.
render_report() {

    exec > >(tee "$TXT") 2>&1

    SRC=$(jq -r '
        (.NowPlayingItem.MediaStreams // []) | map(select(.Type == "Video")) | first // {} |
        [ (.Codec // "?"), (.Width // 0), (.Height // 0),
          (.BitRate // 0), (.RealFrameRate // .AverageFrameRate // 0),
          (.Profile // "?"), (.VideoRange // "?") ] | @tsv' "$JSON")
    IFS=$'\t' read -r S_CODEC S_W S_H S_BR S_FPS S_PROF S_RANGE <<<"$SRC"

    echo "=========================================================="
    echo " Jellyfin stream benchmark: $LABEL"
    echo " $(date -Is)"
    echo "=========================================================="
    echo
    echo "### Client"
    echo
    jq -r '"  device        \(.DeviceName // "?")",
           "  app           \(.Client // "?") \(.ApplicationVersion // "")",
           "  remote addr   \(.RemoteEndPoint // "?")"' "$JSON"
    echo
    echo "### Source file"
    echo
    jq -r '"  title         \(.NowPlayingItem.Name // "?")",
           "  path          \(.NowPlayingItem.Path // "?")",
           "  container     \(.NowPlayingItem.Container // "?")"' "$JSON"
    printf '  video         %s %sx%s %s %s\n' "$S_CODEC" "$S_W" "$S_H" "$S_PROF" "$S_RANGE"
    awk -v br="$S_BR" -v fps="$S_FPS" 'BEGIN {
        printf "  source rate   %.1f Mbit/s at %.3f fps\n", br/1000000, fps }'
    echo
    echo "### Verdict"
    echo

    awk -F'\t' -v warm="$WARMUP" -v sfps="$S_FPS" '
    NR == 1 { next }
    {
        n++
        method[$3]++
        if ($10 != "" && $10 != "none") reasons[$10]++
        if ($8 != "") vc[$8]++
        if ($9 != "") hw[$9]++
        if ($15 != "") vdir[$15]++
        if ($16 != "") adir[$16]++
        if ($2 >= warm) {
            m++
            if ($6 != "") { fps_sum += $6; fps_n++
                            if (fps_min == 0 || $6 < fps_min) fps_min = $6
                            if ($6 > fps_max) fps_max = $6 }
            if ($7 != "") { br_sum += $7; br_n++ }
            if ($11 != "") { cpu_sum += $11; cpu_n++; if ($11 > cpu_max) cpu_max = $11 }
        }
        # A stall is a sample where playback is not paused and the position did
        # not advance since the previous sample.
        if (NR > 2 && $2 >= warm && $5 == "false" && $4 == prev_pos) stalls++
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
    }
    END {
        best = ""; for (k in method) if (best == "" || method[k] > method[best]) best = k
        printf "  play method   %s", best
        if (length(method) > 1) { printf "  (changed during the run: "
            for (k in method) printf "%s=%d ", k, method[k]; printf ")" }
        printf "\n"
        r = ""; for (k in reasons) r = r (r ? ", " : "") k
        printf "  reason        %s\n", (r == "" ? "n/a — no transcode" : r)
        if (length(vc)) { for (k in vc) printf "  output codec  %s\n", k }
        # PlayMethod alone cannot tell a remux from a re-encode. IsVideoDirect can.
        if (best == "Transcode" && length(vdir) == 0) {
            printf "  actually      UNKNOWN. This run predates the IsVideoDirect columns,\n"
            printf "                so a remux cannot be told apart from a re-encode here.\n"
        }
        else if (best == "Transcode") {
            vd = ("true" in vdir) && !("false" in vdir)
            ad = ("true" in adir) && !("false" in adir)
            if (vd && ad)
                printf "  actually      REMUX ONLY. Video and audio are both copied.\n         %s\n", \
                    "     No re-encoding happened, so the cpu figure below is muxing, not encoding."
            else if (vd)
                printf "  actually      audio re-encoded, video copied. Cheap.\n"
            else {
                h = ""; for (k in hw) h = h k
                printf "  actually      video re-encoded.\n"
                printf "  hw accel      %s\n", (h == "" ? "none — software, on the CPU" : h)
            }
        }
        printf "\n### Transcode performance (first %ds excluded)\n\n", warm
        if (fps_n) {
            printf "  encode fps    mean %.1f   min %.1f   max %.1f\n", fps_sum/fps_n, fps_min, fps_max
            printf "  output rate   %.1f Mbit/s\n", (br_n ? br_sum/br_n/1000000 : 0)
            if (sfps > 0) {
                if (length(vdir) > 0 && ("true" in vdir) && !("false" in vdir))
                    printf "  realtime      %.2fx  — but the video is copied, so this is mux throughput, not encode speed\n", (fps_sum/fps_n)/sfps
                else
                    printf "  realtime      %.2fx  (encode fps / source fps; under 1.00x means it cannot keep up)\n", (fps_sum/fps_n)/sfps
            }
        } else print "  not transcoding — no encoder to measure"
        printf "\n### Server load (first %ds excluded)\n\n", warm
        if (cpu_n) printf "  container cpu mean %.1f%%   peak %.1f%%\n", cpu_sum/cpu_n, cpu_max
        else print "  no container stats captured"
        printf "\n### Network\n\n"
        if (first_tx != "" && last_ts > first_ts && last_tx+0 > first_tx+0)
            printf "  mean tx       %.1f Mbit/s over %d s\n", \
                (last_tx-first_tx)*8/(last_ts-first_ts)/1000000, last_ts-first_ts
        else print "  no byte counters captured"
        printf "\n### Playback health\n\n"
        printf "  samples       %d\n", n
        printf "  stalled       %d samples (position did not advance while playing)\n", stalls+0
    }' "$TSV"

    if [[ -n "$FFMPEG_ARGS" ]]; then
        echo
        echo "### Encoder command line"
        echo
        echo "$FFMPEG_ARGS" | fold -w 76 -s | sed 's/^/  /'
    fi

    echo
    echo "  samples: docs/streaming/$LABEL.tsv"
    echo "  session: docs/streaming/$LABEL.session.json"

}

if [[ "$REPORT_ONLY" -eq 1 ]]; then
    for f in "$TSV" "$JSON"; do
        [[ -f "$f" ]] || { echo "error: $f does not exist." >&2; exit 1; }
    done
    render_report
    exit 0
fi

if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
    cat >&2 <<EOF
error: JELLYFIN_API_KEY is not set.

Create one in Jellyfin: Dashboard -> Advanced -> API Keys -> +
Then write it to $ENV_FILE :

    JELLYFIN_API_KEY=<the key>

That path matches the *.local.env gitignore rule, so it stays out of git.
EOF
    exit 1
fi

AUTH=(-H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"")

sessions() {
    curl -sS --max-time 10 "${AUTH[@]}" "$JELLYFIN_URL/Sessions" 2>/dev/null
}

REMOTE_LOG="$(mktemp -t jf-bench-remote.XXXXXX)"
cleanup() {
    [[ -n "${REMOTE_PID:-}" ]] && kill "$REMOTE_PID" 2>/dev/null
    rm -f "$REMOTE_LOG"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- preflight

echo "### Preflight"
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null; then
    echo "  FAIL: cannot ssh to $SSH_HOST. Is pve-prod powered on?" >&2
    exit 1
fi
echo "  ssh $SSH_HOST                    ok"

if ! sessions | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "  FAIL: $JELLYFIN_URL/Sessions did not return a session array." >&2
    echo "        Check the URL and the API key." >&2
    exit 1
fi
echo "  $JELLYFIN_URL/Sessions   ok"

HOST_CPU=$(ssh -o BatchMode=yes "$SSH_HOST" \
    "lscpu | sed -n 's/^Model name: *//p'; nproc" 2>/dev/null | paste -sd' / ')
echo "  server cpu                       $HOST_CPU"
echo

# ------------------------------------------------------------ lock on a session

echo "### Waiting for playback"
echo "  Start the title on the device now. Ctrl-C to abort."
echo

SID=""
for _ in $(seq 1 120); do
    RAW=$(sessions)
    LINE=$(jq -r --arg f "$DEVICE_FILTER" '
        [ .[]
          | select(.NowPlayingItem != null)
          | select($f == "" or ((.DeviceName // "") | ascii_downcase | contains($f | ascii_downcase)))
        ] | first
        | select(. != null)
        | [.Id, (.DeviceName // "?"), (.Client // "?"), (.NowPlayingItem.Name // "?")]
        | @tsv' <<<"$RAW" 2>/dev/null)
    if [[ -n "$LINE" ]]; then
        IFS=$'\t' read -r SID DEV CLI ITEM <<<"$LINE"
        jq --arg id "$SID" '.[] | select(.Id == $id)' <<<"$RAW" > "$JSON"
        echo "  locked on: $DEV / $CLI"
        echo "  playing:   $ITEM"
        break
    fi
    sleep 2
done

if [[ -z "$SID" ]]; then
    echo "  FAIL: no playback session appeared within 240 s." >&2
    exit 1
fi
echo

# ------------------------------------------------------- remote load sampler
#
# One persistent ssh connection streams container stats back. `docker stats`
# costs about 1.5 s per call, so the remote loop free-runs at its own cadence
# and the local loop reads whatever the newest line is. Every line carries its
# own timestamp, so rates are computed from real deltas, not assumed ones.
#
# Byte counters come from the container's own interfaces rather than from
# `docker stats` NET I/O, because the raw /sys counters need no unit parsing.

ssh -o BatchMode=yes "$SSH_HOST" bash -s "$CONTAINER" > "$REMOTE_LOG" 2>/dev/null <<'REMOTE' &
c="$1"
while :; do
    ts=$(date +%s)
    st=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "$c" 2>/dev/null)
    rx=$(docker exec "$c" sh -c 'cat /sys/class/net/eth*/statistics/rx_bytes' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    tx=$(docker exec "$c" sh -c 'cat /sys/class/net/eth*/statistics/tx_bytes' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    echo "$ts|$st|$rx|$tx"
done
REMOTE
REMOTE_PID=$!

# ------------------------------------------------------------------ sampling

printf 'ts\telapsed\tplay_method\tpos_s\tpaused\ttc_fps\ttc_bitrate\ttc_vcodec\ttc_hwaccel\ttc_reasons\tcpu_pct\tmem_mb\trx_bytes\ttx_bytes\tvideo_direct\taudio_direct\n' > "$TSV"

# The lock above accepts a paused session, because a paused session still
# reports NowPlayingItem. Starting the clock there spends the sample window on
# a still frame and drags every average toward idle. Wait for play instead.
echo "### Waiting for play"
PLAY_WAIT=0
while [[ $PLAY_WAIT -lt 240 ]]; do
    P=$(sessions | jq -r --arg id "$SID" '.[] | select(.Id == $id) | .PlayState.IsPaused // false' 2>/dev/null)
    [[ -z "$P" ]] && { echo "  session went away before play was pressed." >&2; exit 1; }
    [[ "$P" == "false" ]] && break
    sleep 2
    PLAY_WAIT=$((PLAY_WAIT + 2))
done
if [[ $PLAY_WAIT -ge 240 ]]; then
    echo "  FAIL: still paused after 240 s." >&2
    exit 1
fi
echo "  playing after ${PLAY_WAIT}s paused"
echo

START=$(date +%s)
END=$((START + DURATION))
FFMPEG_ARGS=""

echo "### Sampling for ${DURATION}s"
while [[ $(date +%s) -lt $END ]]; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    S=$(sessions | jq -r --arg id "$SID" '
        .[] | select(.Id == $id) |
        [ (.PlayState.PlayMethod // "-"),
          ((.PlayState.PositionTicks // 0) / 10000000 | floor),
          (.PlayState.IsPaused // false),
          (.TranscodingInfo.Framerate // ""),
          (.TranscodingInfo.Bitrate // ""),
          (.TranscodingInfo.VideoCodec // ""),
          (.TranscodingInfo.HardwareAccelerationType // ""),
          ((.TranscodingInfo.TranscodeReasons // []) | join(",")),
          (.TranscodingInfo.IsVideoDirect // ""),
          (.TranscodingInfo.IsAudioDirect // "")
        ] | @tsv' 2>/dev/null)

    if [[ -z "$S" ]]; then
        echo "  playback stopped at ${ELAPSED}s — ending run early."
        break
    fi
    IFS=$'\t' read -r PM POS PAUSED FPS BR VC HW REASONS VDIR ADIR <<<"$S"

    R=$(tail -n 1 "$REMOTE_LOG" 2>/dev/null)
    IFS='|' read -r _rts CPU MEM RXB TXB <<<"${R:-|||}"
    CPU="${CPU%\%}"
    MEM="${MEM%% /*}"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NOW" "$ELAPSED" "$PM" "$POS" "$PAUSED" "$FPS" "$BR" "$VC" "$HW" \
        "${REASONS:-none}" "${CPU:-}" "${MEM:-}" "${RXB:-}" "${TXB:-}" \
        "${VDIR:-}" "${ADIR:-}" >> "$TSV"

    # Capture the encoder command line once, the first time a transcode is seen.
    if [[ "$PM" == "Transcode" && -z "$FFMPEG_ARGS" ]]; then
        FFMPEG_ARGS=$(ssh -o BatchMode=yes "$SSH_HOST" \
            "ps -eo comm= -o args= | awk '\$1 == \"ffmpeg\" { \$1 = \"\"; print; exit }'" 2>/dev/null)
    fi

    printf '\r  %3ss  %-12s pos=%-5ss fps=%-6s cpu=%-7s' \
        "$ELAPSED" "$PM" "$POS" "${FPS:0:6}" "${CPU:-?}%"
    sleep 2
done
echo
echo

kill "$REMOTE_PID" 2>/dev/null
REMOTE_PID=""

render_report
