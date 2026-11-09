#!/usr/bin/env python3
"""Bazarr custom post-processing (Settings > Subtitles > Post-Processing):

  python3 /scripts/companion-subs.py "{{episode}}" "{{subtitles}}"

{{episode}} is the video path for movies too.

Jellyfin shows an external subtitle only on the version whose file name it
starts with. Bazarr names the subtitle after the original, so the 720p
companion (see docs/media/TRANSCODING.md) would not get it. This copies the
subtitle under the companion's name and keeps the ".en.srt" / ".en.forced.srt"
suffix. Tested on Parasite, 2026-11-09. Bazarr runs it again on a subtitle
upgrade, so the copy gets the new subtitle too.

Also usable by hand: with only a video path, it copies every external
subtitle of that video.
"""
import os
import re
import shutil
import sys

SUFFIX = ' - 720p.mkv'
SUBEXT = re.compile(r'\.(srt|ass|ssa|vtt)$', re.I)


def companion_of(video):
    # Same rule as the Tdarr flow (build_flow.py companionOf).
    d, b = os.path.split(video)
    ep = re.match(r'^(.*?\bS\d{1,4}E\d{1,4}(?:-?E\d{1,4})*)', b, re.I)
    return os.path.join(d, (ep.group(1) if ep else os.path.basename(d)) + SUFFIX)


def main():
    video = sys.argv[1]
    if video.endswith(SUFFIX):
        return
    comp = companion_of(video)
    if not os.path.exists(comp):
        return
    d = os.path.dirname(video)
    vstem = os.path.splitext(os.path.basename(video))[0]
    cstem = os.path.splitext(os.path.basename(comp))[0]
    subs = sys.argv[2:] or [os.path.join(d, f) for f in os.listdir(d)]
    for s in subs:
        name = os.path.basename(s)
        if name.startswith(vstem + '.') and SUBEXT.search(name):
            dst = os.path.join(d, cstem + name[len(vstem):])
            shutil.copyfile(s, dst)
            print('companion-subs: ' + dst)


if __name__ == '__main__':
    main()
