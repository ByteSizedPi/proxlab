#!/usr/bin/env python3
"""Write 720p H.264 companion files for media that cannot direct play.

Runs on pve-prod. Calls ffprobe and ffmpeg inside the jellyfin container,
because that container holds jellyfin-ffmpeg 8.1 with the tonemapx filter.

Sources are never modified. Output mirrors the source tree into a sibling
folder, which becomes a second Jellyfin library. See
docs/media/TRANSCODING.md for why the output does not go beside the source.

Resumable. A file whose output already exists is skipped, so the nightly
power-off of pve-prod costs at most one part-finished file.
"""

import json
import os
import shlex
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

FFMPEG = "/usr/lib/jellyfin-ffmpeg/ffmpeg"
FFPROBE = "/usr/lib/jellyfin-ffmpeg/ffprobe"
CONTAINER = "jellyfin"

# Container paths. /mnt/data on the host is /data in the container.
PAIRS = [
    ("/data/media/tv", "/data/media/tv-720p"),
    ("/data/media/movies", "/data/media/movies-720p"),
]
SCRATCH = "/data/transcode"

VIDEO_EXT = (".mkv", ".mp4", ".m4v", ".avi", ".ts", ".m2ts")
TEXT_SUBS = {"subrip", "ass", "ssa", "mov_text", "webvtt", "text"}
HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}

WORKERS = 2
# 10 threads per job drove the pve-prod load average to 16.9 with ONE job
# running, because x264 and the 2160p decoder each take threads. 8 keeps two
# jobs inside 24 vCPUs. Every process is nice 19, so direct play still wins.
THREADS = 8
NICE = 19

# PUID and PGID from stacks/common.env.
OWNER_UID = 1000
OWNER_GID = 1000


def dexec(args, timeout=None):
    """Run one command inside the jellyfin container."""
    cmd = ["docker", "exec", CONTAINER, "nice", "-n", str(NICE)] + args
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


_PROBE_CACHE = {}


def probe(path):
    """ffprobe one file. Cached, because main() and encode() both ask."""
    if path in _PROBE_CACHE:
        return _PROBE_CACHE[path]
    r = dexec([FFPROBE, "-v", "quiet", "-print_format", "json",
               "-show_streams", "-show_format", path], timeout=120)
    info = None
    if r.returncode == 0:
        try:
            info = json.loads(r.stdout)
        except json.JSONDecodeError:
            info = None
    _PROBE_CACHE[path] = info
    return info


def list_sources():
    """Every video file under each source root, as container paths."""
    out = []
    for src, dst in PAIRS:
        r = dexec(["find", src, "-type", "f"], timeout=120)
        for line in r.stdout.splitlines():
            if line.lower().endswith(VIDEO_EXT):
                out.append((line, src, dst))
    return out


def needs_companion(info):
    """True when a browser or a phone cannot direct play this file.

    The filter is the one recorded in docs/media/TRANSCODING.md: video codec
    is not h264, or height is above 1080.
    """
    v = next((s for s in info["streams"] if s.get("codec_type") == "video"), None)
    if v is None:
        return False, None
    codec = v.get("codec_name", "")
    height = int(v.get("height") or 0)
    return (codec != "h264" or height > 1080), v


def build_args(src, tmp, info, vstream):
    hdr = vstream.get("color_transfer") in HDR_TRANSFERS
    scale = ("scale=1280:720:force_original_aspect_ratio=decrease"
             ":force_divisible_by=2")
    if hdr:
        # Scale in the source bit depth first, then tone map down to 8-bit.
        # Scaling first is cheaper and keeps 10-bit precision through the
        # resize. apply_dovi defaults to true, which is correct here: every
        # Dolby Vision file in this library is profile 8 and carries an
        # HDR10 base layer.
        vf = (scale + ",tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709"
              ":primaries=bt709:range=tv:format=yuv420p:desat=0")
    else:
        vf = scale + ",format=yuv420p"

    audio = [s for s in info["streams"] if s.get("codec_type") == "audio"]
    subs = [s for s in info["streams"]
            if s.get("codec_type") == "subtitle"
            and s.get("codec_name") in TEXT_SUBS]

    args = [FFMPEG, "-nostdin", "-y", "-hide_banner", "-loglevel", "warning",
            "-i", src, "-map", "0:v:0"]

    # Output audio 0 is AAC stereo, because no browser decodes eac3 or dts.
    # Every original audio track is then copied, so the TV keeps 5.1.
    if audio:
        args += ["-map", "0:a:0"]
        for s in audio:
            args += ["-map", "0:" + str(s["index"])]
    for s in subs:
        args += ["-map", "0:" + str(s["index"])]

    args += ["-map_chapters", "0", "-vf", vf,
             "-c:v", "libx264", "-preset", "medium", "-crf", "21",
             "-maxrate", "3M", "-bufsize", "6M",
             "-profile:v", "high", "-level", "4.0",
             "-threads", str(THREADS),
             "-c:a", "copy", "-c:s", "copy"]
    if audio:
        args += ["-c:a:0", "aac", "-b:a:0", "160k", "-ac:a:0", "2",
                 "-metadata:s:a:0", "title=Stereo (AAC)",
                 "-disposition:a", "0", "-disposition:a:0", "default"]
        lang = audio[0].get("tags", {}).get("language")
        if lang:
            args += ["-metadata:s:a:0", "language=" + lang]
    args += ["-max_muxing_queue_size", "1024", tmp]
    return args, hdr


def encode(job):
    src, root, dst_root = job
    rel = os.path.relpath(src, root)
    out = os.path.join(dst_root, os.path.splitext(rel)[0] + ".mkv")

    host_out = out.replace("/data/", "/mnt/data/", 1)
    if os.path.exists(host_out) and os.path.getsize(host_out) > 0:
        return ("skip", src, "output exists")

    info = probe(src)
    if info is None:
        return ("fail", src, "ffprobe failed")
    wanted, vstream = needs_companion(info)
    if not wanted:
        return ("pass", src, "already direct plays")

    tmp = os.path.join(SCRATCH, "enc-%d-%s.mkv" % (os.getpid(), str(time.time())))
    args, hdr = build_args(src, tmp, info, vstream)

    dexec(["mkdir", "-p", os.path.dirname(out)])
    t0 = time.time()
    r = dexec(args, timeout=6 * 3600)
    took = time.time() - t0

    if r.returncode != 0:
        dexec(["rm", "-f", tmp])
        return ("fail", src, (r.stderr or "").strip()[-400:])

    mv = dexec(["mv", tmp, out])
    if mv.returncode != 0:
        return ("fail", src, "move failed: " + (mv.stderr or "").strip())

    # ffmpeg ran as root, because docker exec does not assume the container
    # user. The rest of the library is 1000:1000, so match it.
    dexec(["chown", "-R", "%d:%d" % (OWNER_UID, OWNER_GID), os.path.dirname(out)])
    dexec(["chmod", "664", out])

    size = os.path.getsize(host_out) if os.path.exists(host_out) else 0
    return ("ok", src,
            "%s  %.0f min  %.0f MB" % ("HDR" if hdr else "SDR",
                                       took / 60, size / 1e6))


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 0

    print("scanning", flush=True)
    sources = list_sources()
    print("found %d video files" % len(sources), flush=True)

    jobs = []
    for job in sources:
        info = probe(job[0])
        if info is None:
            continue
        wanted, _ = needs_companion(info)
        if wanted:
            jobs.append(job)
    print("%d need a companion" % len(jobs), flush=True)
    if limit:
        jobs = jobs[:limit]
        print("limited to %d" % len(jobs), flush=True)

    counts = {"ok": 0, "skip": 0, "fail": 0, "pass": 0}
    done = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for status, src, note in pool.map(encode, jobs):
            counts[status] += 1
            done += 1
            print("[%d/%d] %-5s %s  (%s)"
                  % (done, len(jobs), status, os.path.basename(src), note),
                  flush=True)

    for _, dst in PAIRS:
        dexec(["chown", "-R", "%d:%d" % (OWNER_UID, OWNER_GID), dst])

    print("\ndone: " + ", ".join("%s=%d" % kv for kv in counts.items()),
          flush=True)
    return 1 if counts["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
