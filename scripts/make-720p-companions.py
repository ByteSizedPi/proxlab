#!/usr/bin/env python3
"""Write 720p H.264 companion files for media that cannot direct play.

Runs on pve-prod as the jj user. See docs/media/TRANSCODING.md for why this
exists, what the target format is, and why the output does not go beside the
source.

ffmpeg runs in a THROWAWAY container built from the jellyfin image, not through
`docker exec jellyfin`. Two reasons:

1. The jellyfin stack has auto_update and poll_for_updates on, and Komodo polls
   every 5 minutes. A new jellyfin:latest recreates the container, which kills
   any `docker exec` running inside it. A throwaway container does not care.
2. `docker exec` runs as root, so output landed root:root. `--user 1000:1000`
   writes files owned by jj directly, with no chown step.

The image is needed only for jellyfin-ffmpeg 8.1 and its tonemapx filter.

Sources are never modified. Resumable: a file whose output already exists is
skipped, so the nightly power-off of pve-prod costs at most one part-finished
file.
"""

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

IMAGE = "lscr.io/linuxserver/jellyfin:latest"
FFMPEG = "/usr/lib/jellyfin-ffmpeg/ffmpeg"
FFPROBE = "/usr/lib/jellyfin-ffmpeg/ffprobe"

# Container paths. /mnt/data on the host is /data in the container.
HOST_ROOT = "/mnt/data"
CONT_ROOT = "/data"
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
# jobs inside 24 vCPUs. Every container is nice 19, so direct play still wins.
THREADS = 8
NICE = 19
OWNER = "1000:1000"


def host(p):
    """Container path to host path."""
    return p.replace(CONT_ROOT + "/", HOST_ROOT + "/", 1)


# Every container this script starts carries this name prefix, so an
# interrupted run can be cleaned up with one command:
#   docker ps -a --filter name=c720- -q | xargs -r docker rm -f
# Killing the python process alone does NOT stop the containers. The docker
# run client dies, the container keeps encoding, and its output goes to a
# scratch file nothing will move.
NAME_PREFIX = "c720-"


def drun(entrypoint, args, timeout=None):
    """Run one binary from the jellyfin image in a throwaway container.

    `nice` goes INSIDE the container. A container does not inherit the nice
    value of the `docker run` client, because the daemon starts the process,
    not the client. Measured: the docker client sat at nice 19 while ffmpeg
    ran at nice 0. --cpu-shares lowers the cgroup weight as well, which is the
    part the kernel honours under real contention.
    """
    name = "%s%d-%d" % (NAME_PREFIX, os.getpid(), time.time_ns())
    cmd = ["docker", "run", "--rm",
           "--name", name,
           "--cpu-shares", "256",
           "--user", OWNER, "-v", HOST_ROOT + ":" + CONT_ROOT,
           "--entrypoint", "/usr/bin/nice", IMAGE,
           "-n", str(NICE), entrypoint] + args
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        subprocess.run(["docker", "rm", "-f", name],
                       capture_output=True, text=True)
        raise


def scan():
    """One container call returns codec and height for every video file.

    Probing 244 files one container at a time costs about 4 minutes of pure
    container startup, so the cheap pass runs as a single shell loop inside one
    container. Only the candidates get a full probe afterwards.
    """
    roots = " ".join("'%s'" % src for src, _ in PAIRS)
    script = (
        'find %s -type f 2>/dev/null | while read -r f; do '
        'case "$f" in *.mkv|*.mp4|*.m4v|*.avi|*.ts|*.m2ts) ;; *) continue;; esac; '
        '%s -v quiet -select_streams v:0 -show_entries stream=codec_name,height '
        '-of csv=p=0 "$f" 2>/dev/null | head -1 | tr -d "\\n"; '
        'printf "|%%s\\n" "$f"; done' % (roots, FFPROBE)
    )
    r = drun("/bin/sh", ["-c", script], timeout=1800)
    rows = []
    for line in r.stdout.splitlines():
        if "|" not in line:
            continue
        head, path = line.split("|", 1)
        parts = head.split(",")
        codec = parts[0] if parts else ""
        try:
            height = int(parts[1])
        except (IndexError, ValueError):
            height = 0
        rows.append((codec, height, path))
    return rows


def probe(path):
    """Full stream list for one file."""
    r = drun(FFPROBE, ["-v", "quiet", "-print_format", "json",
                       "-show_streams", path], timeout=300)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def needs_companion(codec, height):
    """The filter recorded in docs/media/TRANSCODING.md.

    Video codec is not h264, or height is above 1080. A browser decodes neither
    HEVC nor Dolby Vision, and many phone decoders cap h264 at 1080p.
    """
    return codec != "h264" or height > 1080


def build_args(src, tmp, info):
    vstream = next(s for s in info["streams"] if s.get("codec_type") == "video")
    hdr = vstream.get("color_transfer") in HDR_TRANSFERS
    scale = ("scale=1280:720:force_original_aspect_ratio=decrease"
             ":force_divisible_by=2")
    if hdr:
        # Scale in the source bit depth first, then tone map down to 8-bit.
        # Scaling first is cheaper and keeps 10-bit precision through the
        # resize. apply_dovi defaults to true, which is correct here: every
        # Dolby Vision file in this library is profile 8 and carries an HDR10
        # base layer, so tone mapping reads real metadata.
        vf = (scale + ",tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709"
              ":primaries=bt709:range=tv:format=yuv420p:desat=0")
    else:
        vf = scale + ",format=yuv420p"

    audio = [s for s in info["streams"] if s.get("codec_type") == "audio"]
    subs = [s for s in info["streams"]
            if s.get("codec_type") == "subtitle"
            and s.get("codec_name") in TEXT_SUBS]

    args = ["-nostdin", "-y", "-hide_banner", "-loglevel", "warning",
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
    host_out = host(out)

    if os.path.exists(host_out) and os.path.getsize(host_out) > 0:
        return ("skip", src, "output exists")

    info = probe(src)
    if info is None:
        return ("fail", src, "ffprobe failed")
    if not any(s.get("codec_type") == "video" for s in info["streams"]):
        return ("fail", src, "no video stream")

    tmp = os.path.join(SCRATCH, "enc-%d-%d.mkv" % (os.getpid(), time.time_ns()))
    host_tmp = host(tmp)
    args, hdr = build_args(src, tmp, info)

    os.makedirs(os.path.dirname(host_out), exist_ok=True)
    t0 = time.time()
    r = drun(FFMPEG, args, timeout=6 * 3600)
    took = time.time() - t0

    if r.returncode != 0:
        if os.path.exists(host_tmp):
            os.remove(host_tmp)
        return ("fail", src, (r.stderr or "").strip()[-400:])

    # Scratch and output share /dev/sdc, so this is a rename, not a copy.
    os.replace(host_tmp, host_out)
    os.chmod(host_out, 0o664)

    size = os.path.getsize(host_out)
    return ("ok", src, "%s  %.0f min  %.0f MB"
            % ("HDR" if hdr else "SDR", took / 60, size / 1e6))


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 0

    # A previous interrupted run may have left containers encoding.
    stale = subprocess.run(
        ["docker", "ps", "-aq", "--filter", "name=" + NAME_PREFIX],
        capture_output=True, text=True).stdout.split()
    if stale:
        print("removing %d container(s) from an earlier run" % len(stale),
              flush=True)
        subprocess.run(["docker", "rm", "-f"] + stale, capture_output=True)
    for f in os.listdir(host(SCRATCH)):
        if f.startswith("enc-") and f.endswith(".mkv"):
            os.remove(os.path.join(host(SCRATCH), f))

    print("scanning", flush=True)
    rows = scan()
    print("found %d video files" % len(rows), flush=True)

    jobs = []
    for codec, height, path in rows:
        if not needs_companion(codec, height):
            continue
        for src_root, dst_root in PAIRS:
            if path.startswith(src_root + "/"):
                jobs.append((path, src_root, dst_root))
                break
    print("%d need a companion" % len(jobs), flush=True)
    if limit:
        jobs = jobs[:limit]
        print("limited to %d" % len(jobs), flush=True)

    counts = {"ok": 0, "skip": 0, "fail": 0}
    done = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for status, src, note in pool.map(encode, jobs):
            counts[status] += 1
            done += 1
            print("[%d/%d] %-5s %s  (%s)"
                  % (done, len(jobs), status, os.path.basename(src), note),
                  flush=True)

    print("\ndone: " + ", ".join("%s=%d" % kv for kv in counts.items()),
          flush=True)
    return 1 if counts["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
