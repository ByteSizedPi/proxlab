#!/bin/bash
# Sonarr/Radarr "Custom Script" connection, on file delete (also on upgrade).
#
# Tdarr writes a 720p companion next to each original that a browser cannot
# play, named "<prefix> - 720p.mkv" (see docs/media/TRANSCODING.md). Sonarr
# and Radarr do not know that file, so when they delete the original
# (Maintainerr cleanup, manual delete, upgrade) the companion would stay
# behind as a stray Jellyfin version. This deletes it. On an upgrade Tdarr
# then writes a new companion from the new file, if the new file needs one.
set -u

# Remove a companion and its subtitle copies ("<companion stem>.en.srt" etc,
# written by the Tdarr flow and by companion-subs.sh).
rmc() {
  [ -e "$1" ] || return 0
  for s in "${1%.mkv}".*.srt "${1%.mkv}".*.ass "${1%.mkv}".*.ssa "${1%.mkv}".*.vtt; do
    [ -e "$s" ] && rm -v -- "$s"
  done
  rm -v -- "$1"
}

# Sonarr documents these variables in lower case but sets them as
# Sonarr_EpisodeFile_Path etc. Match either spelling.
ev() { env | grep -i "^$1=" | head -1 | cut -d= -f2-; }

event=$(ev sonarr_eventtype)
[ -n "$event" ] || event=$(ev radarr_eventtype)

case "$event" in
  EpisodeFileDelete)
    f=$(ev sonarr_episodefile_path)
    # Same token rule as the Tdarr flow: the first SxxEyy[-Ezz] in the name.
    tok=$(basename "$f" | grep -oE 'S[0-9]+E[0-9]+(-?E[0-9]+)*' | head -1)
    [ -n "$tok" ] || exit 0
    for c in "$(dirname "$f")"/*" - $tok - 720p.mkv"; do
      rmc "$c"
    done
    ;;
  MovieFileDelete)
    f=$(ev radarr_moviefile_path)
    d=$(dirname "$f")
    c="$d/$(basename "$d") - 720p.mkv"
    rmc "$c"
    ;;
esac
exit 0
