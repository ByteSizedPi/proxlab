#!/usr/bin/env bash
#
# Measure the home network so a router swap can be judged on numbers.
#
# Run it once before changing hardware and once after. Pass a label:
#
#     scripts/wifi-benchmark.sh before-ax10
#     scripts/wifi-benchmark.sh after-ax10
#
# Each run writes docs/network/<label>.txt. Compare two runs with:
#
#     diff -u docs/network/before-ax10.txt docs/network/after-ax10.txt
#
# Deliberately uses only tools already present (iw, nmcli, curl, ethtool, ssh).
# Nothing gets installed, so the "after" run cannot be spoiled by a tool
# behaving differently from the "before" run.
#
# Two measurement points, because they answer different questions:
#
#   jjserver  wired to the main router. Shows what the fibre line delivers
#             when WiFi is not involved. This is the ceiling.
#   laptop    on the room WiFi. Shows what a phone or TV in that room gets.
#
# The gap between the two IS the WiFi problem. Closing it is the whole point
# of the router upgrade.

set -uo pipefail

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
    echo "usage: $0 <label>    e.g. $0 before-ax10" >&2
    exit 1
fi

WIFI_IF="wlp0s20f3"
SERVER="jjserver"
SERVER_IF="eno1"
# 50 MB. Big enough that TCP leaves slow start, small enough to stay quick on
# a bad link.
BYTES=52428800
RUNS=3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/network"
OUT="$OUT_DIR/$LABEL.txt"
mkdir -p "$OUT_DIR"

# Everything below goes to both the terminal and the report file.
exec > >(tee "$OUT") 2>&1

echo "=========================================================="
echo " Network benchmark: $LABEL"
echo " $(date -Is)"
echo "=========================================================="
echo

echo "### Laptop WiFi link"
echo
iw dev "$WIFI_IF" link 2>&1 | grep -iE "ssid|freq|signal|bitrate" || echo "  (no link)"
echo
echo "  negotiated rates above are PHY rates, not throughput."
echo "  expect real throughput near half the PHY rate at best."
echo

echo "### Laptop WiFi capability (does not change between runs)"
echo
# Captured once, then matched in memory. Do NOT pipe iw into `grep -q` here:
# grep -q exits on first match, iw takes SIGPIPE, and `set -o pipefail` turns
# that into a failed pipeline. The result is a false "no" that appears or
# vanishes depending on how much iw had already flushed.
PHY_INFO=$(iw phy 2>/dev/null)
yesno() { [[ "$1" -gt 0 ]] && echo yes || echo no; }
echo "  5 GHz band present: $(yesno "$(grep -c 'Band 2:' <<<"$PHY_INFO")")"
echo "  6 GHz band present: $(yesno "$(grep -c 'Band 4:' <<<"$PHY_INFO")")"
echo "  802.11ax (HE) capable: $(yesno "$(grep -c 'HE ' <<<"$PHY_INFO")")"
echo

echo "### Visible networks"
echo
nmcli -f SSID,CHAN,FREQ,RATE,SIGNAL dev wifi list 2>&1 | head -15
echo
echo -n "  networks on 5 GHz: "
nmcli -f FREQ dev wifi list 2>/dev/null | grep -cE "5[0-9]{3} MHz"
echo

echo "### Wired link on $SERVER"
echo
ssh -o ConnectTimeout=8 "$SERVER" \
    "ethtool $SERVER_IF 2>/dev/null | grep -iE 'speed|duplex|link detected'" \
    2>&1 | sed 's/^/  /'
echo
echo "  what the router port offers:"
ssh -o ConnectTimeout=8 "$SERVER" \
    "ethtool $SERVER_IF 2>/dev/null | sed -n '/Link partner advertised link modes/,/pause frame/p' | head -4" \
    2>&1 | sed 's/^/  /'
echo

echo "### Latency"
echo
GW=$(ip route | awk '/^default/{print $3; exit}')
echo "  laptop -> gateway ($GW):"
ping -c 10 -i 0.2 -W 2 "$GW" 2>&1 | tail -2 | sed 's/^/    /'
echo "  laptop -> internet (1.1.1.1):"
ping -c 10 -i 0.2 -W 2 1.1.1.1 2>&1 | tail -2 | sed 's/^/    /'
echo

# speed_download is bytes/sec. Multiply by 8, divide by 1e6, for Mbps.
#
# The curl command is built as ONE quoted string. jjserver's login shell is
# zsh, which treats the `?` in the query string as a glob and aborts with
# "no matches found" if the URL reaches it unquoted through ssh.
CURL_CMD="curl -o /dev/null -s -w '%{speed_download}' --max-time 60 'https://speed.cloudflare.com/__down?bytes=$BYTES'"

run_download() {
    local where="$1" host="$2"
    local total=0 n=0
    for i in $(seq 1 $RUNS); do
        local bps
        if [[ -n "$host" ]]; then
            bps=$(ssh -o ConnectTimeout=8 "$host" "$CURL_CMD" 2>/dev/null)
        else
            bps=$(eval "$CURL_CMD" 2>/dev/null)
        fi
        bps=${bps%%.*}
        if [[ -z "$bps" || "$bps" == "0" ]]; then
            echo "    run $i: FAILED"
            continue
        fi
        printf "    run %d: %6.1f Mbps\n" "$i" "$(echo "$bps * 8 / 1000000" | bc -l)"
        total=$((total + bps)); n=$((n + 1))
    done
    if [[ $n -gt 0 ]]; then
        printf "    %-8s average: %6.1f Mbps\n" "$where" \
               "$(echo "$total / $n * 8 / 1000000" | bc -l)"
    fi
}

echo "### Download throughput"
echo
echo "  jjserver, wired (the ceiling):"
run_download "wired" "$SERVER"
echo
echo "  laptop, room WiFi (what a phone or TV sees):"
run_download "wifi" ""
echo

echo "=========================================================="
echo " Report written to $OUT"
echo "=========================================================="
