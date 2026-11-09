#!/usr/bin/env python3
"""Emit the Tdarr flow document for in-folder 720p companions (movies + TV).

The flow lives in Tdarr's database, not in a file Tdarr reads. This script is
the source of truth. To change the flow, edit this file, then on pve-prod:

  python3 build_flow.py | docker exec -i tdarr curl -s -X POST \
    -H 'Content-Type: application/json' --data-binary @- \
    http://localhost:8266/api/v2/cruddb

That is an insert. For an existing flow, delete it first (mode removeOne,
docID flowCompanion720) or send an update with only flowPlugins/flowEdges.
See docs/media/TRANSCODING.md.
"""
import json

# Shared by the three custom functions. Movies: "<folder name> - 720p.mkv".
# Episodes: "<name up to and including SxxEyy[-Ezz]> - 720p.mkv". Both names
# survive a Radarr/Sonarr upgrade of the original, so a new companion
# overwrites the old one instead of leaving an orphan.
HELPER = r"""
const fs = require('fs');
const path = require('path');
const SUFFIX = ' - 720p.mkv';
const isCompanion = (p) => path.basename(p).endsWith(SUFFIX);
const companionOf = (orig) => {
  const dir = path.dirname(orig);
  const ep = path.basename(orig).match(/^(.*?\bS\d{1,4}E\d{1,4}(?:-?E\d{1,4})*)/i);
  const name = (ep ? ep[1] : path.basename(dir)) + SUFFIX;
  const out = path.join(dir, name);
  if (!/^\/media\/(movies|tv)\//.test(out)) throw new Error('Refusing path outside /media/movies or /media/tv: ' + out);
  return out;
};
// External subtitles of the original ("<original>.en.srt", ".en.forced.srt",
// ...) belong to the original only in Jellyfin. A copy named after the
// companion shows on the 720p version too (tested on Parasite, 2026-11-09).
const SUBEXT = /\.(srt|ass|ssa|vtt)$/i;
const stem = (p) => path.basename(p).replace(/\.[^.]+$/, '');
const companionSubs = (dst) => fs.readdirSync(path.dirname(dst))
  .filter((f) => f.startsWith(stem(dst) + '.') && SUBEXT.test(f));
// Log line on ntfy topic srv-log (priority 2, no push). The token is in
// /app/configs/ntfy-token (CONFIG_ROOT, not git; ntfy user "alerts", label
// "tdarr"). A failed post never fails the job. See docs/NOTIFICATIONS.md.
const notify = async (title, msg) => {
  try {
    const tok = fs.readFileSync('/app/configs/ntfy-token', 'utf8').trim();
    await fetch('http://ntfy/srv-log', { method: 'POST', body: msg, signal: AbortSignal.timeout(10000),
      headers: { Authorization: 'Bearer ' + tok, Title: title, Priority: '2', Tags: 'film_frames' } });
  } catch (e) { /* notification only */ }
};
const done = (args, n) => ({ outputFileObj: args.inputFileObj, outputNumber: n, variables: args.variables });
"""

GUARD = HELPER + r"""
module.exports = async (args) => {
  // Output 2 ends the flow: never make a companion of a companion.
  if (isCompanion(args.originalLibraryFile._id)) { args.jobLog('Companion file, skipping'); return done(args, 2); }
  // Per-file stream selection, read by the encode step as mapArgs and
  // codecArgs (2026-11-09):
  //  - Audio 1: AAC stereo, made from the first track. The default track.
  //  - Audio 2: the first LOSSY track with more than 2 channels, copied, for
  //    surround on a laptop or soundbar. Never TrueHD/DTS/FLAC: the copied
  //    TrueHD made the Mad Max companion 7.0 GB, and no phone decodes it.
  //    No such track: no second track (a stereo copy only repeats track 1).
  //  - Subtitles: text only. MP4 mov_text becomes SRT (MKV cannot hold
  //    mov_text). Image subtitles (PGS, VobSub) are dropped: on a phone
  //    they force Jellyfin to burn them in, a full live transcode. The
  //    original's external .srt files are copied in the PLACE step instead.
  const st = (args.inputFileObj.ffProbeData || {}).streams || [];
  const aud = st.filter((x) => x.codec_type === 'audio');
  const LOSSY = ['ac3', 'eac3', 'aac', 'mp3', 'opus', 'vorbis'];
  const sur = aud.findIndex((a) => LOSSY.includes(a.codec_name) && (a.channels || 0) > 2);
  let mapArgs = '-map 0:v:0 -map 0:a:0';
  let codecArgs = '-c:a:0 aac -ac:a:0 2 -b:a:0 192k -disposition:a:0 default';
  if (sur >= 0) { mapArgs += ' -map 0:a:' + sur; codecArgs += ' -c:a:1 copy -disposition:a:1 0'; }
  const TEXT = ['subrip', 'ass', 'ssa', 'mov_text', 'webvtt', 'text'];
  let j = 0;
  st.filter((x) => x.codec_type === 'subtitle').forEach((x, i) => {
    if (!TEXT.includes(x.codec_name)) return;
    mapArgs += ' -map 0:s:' + i;
    codecArgs += ' -c:s:' + j + ' ' + (x.codec_name === 'mov_text' ? 'srt' : 'copy') + ' -disposition:s:' + j + ' 0';
    j++;
  });
  args.variables.user = Object.assign({}, args.variables.user, { mapArgs, codecArgs });
  return done(args, 1);
};
"""

PLACE = HELPER + r"""
module.exports = async (args) => {
  const src = args.inputFileObj._id;
  const dst = companionOf(args.originalLibraryFile._id);
  // /temp and /media are separate bind mounts, so rename() gives EXDEV.
  // Copy next to the target, then rename inside the folder (atomic).
  fs.copyFileSync(src, dst + '.partial');
  fs.renameSync(dst + '.partial', dst);
  args.jobLog('Companion written: ' + dst);
  const mb = Math.round(fs.statSync(dst).size / 1e6);
  await notify('Tdarr: 720p companion', path.basename(dst) + ' (' + mb + ' MB)');
  const orig = args.originalLibraryFile._id, dir = path.dirname(orig), os = stem(orig);
  fs.readdirSync(dir).filter((f) => f.startsWith(os + '.') && SUBEXT.test(f)).forEach((f) => {
    fs.copyFileSync(path.join(dir, f), path.join(dir, stem(dst) + f.slice(os.length)));
    args.jobLog('Subtitle copied for the companion: ' + f);
  });
  return done(args, 1);
};
"""

REMOVE = HELPER + r"""
module.exports = async (args) => {
  // The original no longer needs a companion (e.g. upgraded to h264 1080p
  // SDR). Remove a stale one so Jellyfin stops offering it.
  const orig = args.originalLibraryFile._id;
  const dst = companionOf(orig);
  if (dst !== orig && fs.existsSync(dst)) {
    companionSubs(dst).forEach((f) => fs.unlinkSync(path.join(path.dirname(dst), f)));
    fs.unlinkSync(dst); args.jobLog('Removed stale companion ' + dst);
  }
  return done(args, 1);
};
"""

COMMON_IN = '-hide_banner -i "{{{args.inputFileObj._id}}}" {{{args.variables.user.mapArgs}}}'
# The original's mkvmerge statistics tags (BPS, NUMBER_OF_BYTES, ...) are
# copied as they are and are then wrong: the Mad Max companion said 20
# Mbit/s video. An empty value deletes a tag. Language and title tags stay.
CLEAR_STATS = ' '.join('-metadata:s %s=' % t for t in (
    'BPS', 'DURATION', 'NUMBER_OF_FRAMES', 'NUMBER_OF_BYTES', '_STATISTICS_TAGS',
    '_STATISTICS_WRITING_APP', '_STATISTICS_WRITING_DATE_UTC'))
COMMON_OUT = (
    '-c:v libx264 -preset medium -profile:v high -crf 22 -maxrate 2500k -bufsize 5000k '
    '{{{args.variables.user.codecArgs}}} -map_chapters 0 ' + CLEAR_STATS + ' '
    '-max_muxing_queue_size 9999 -y "${outputFilePath}"'
)
VF_HDR = ('-vf "scale=-2:720,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,'
          'tonemapx=tonemap=bt2390:desat=0:peak=100:t=bt709:m=bt709:p=bt709:format=yuv420p"')
VF_SDR = "-vf \"scale=-2:'min(720,ih)',format=yuv420p\""


def node(nid, name, plugin, x, y, inputs=None):
    return {"name": name, "sourceRepo": "Community", "pluginName": plugin, "version": "1.0.0",
            "id": nid, "position": {"x": x, "y": y}, "inputsDB": inputs or {}}


def run_cli(nid, name, vf, x, y):
    return node(nid, name, "runCli", x, y, {
        "userCli": "ffmpeg", "doesCommandCreateOutputFile": "true",
        "userOutputFilePath": "${cacheDir}/${fileName}.mkv",
        "cliArguments": f"{COMMON_IN} {vf} {COMMON_OUT}",
        "outputFileBecomesWorkingFile": "true",
    })


nodes = [
    node("in", "Input File", "inputFile", 0, 0),
    node("guard", "Skip companions", "customFunction", 0, 100, {"code": GUARD}),
    node("codec", "Is h264?", "checkVideoCodec", 0, 200, {"codec": "h264"}),
    node("res", "Resolution", "checkVideoResolution", -250, 300),
    node("hdrA", "h264 <=1080p: HDR?", "checkHdr", -250, 420),
    node("hdrB", "Needs companion: HDR?", "checkHdr", 250, 420),
    node("remove", "No companion needed: remove stale one", "customFunction", -450, 540, {"code": REMOVE}),
    run_cli("cliH", "Encode 720p SDR (tone map)", VF_HDR, -100, 540),
    run_cli("cliS", "Encode 720p SDR", VF_SDR, 300, 540),
    node("place", "Write '<name> - 720p.mkv' next to original", "customFunction", 100, 660, {"code": PLACE}),
    node("reset", "Working file = original (never replace)", "setWorkingFile", 100, 770, {"source": "originalFile"}),
]
pairs = [("in", 1, "guard"), ("guard", 1, "codec"), ("codec", 1, "res"), ("codec", 2, "hdrB")]
pairs += [("res", n, "hdrA") for n in (1, 2, 3, 4)]
pairs += [("res", n, "hdrB") for n in (5, 6, 7, 8, 9)]
pairs += [("hdrA", 1, "cliH"), ("hdrA", 2, "remove"), ("hdrB", 1, "cliH"), ("hdrB", 2, "cliS"),
          ("cliH", 1, "place"), ("cliS", 1, "place"), ("place", 1, "reset")]
edges = [{"source": s, "sourceHandle": str(h), "target": t, "targetHandle": None, "id": f"e{i}"}
         for i, (s, h, t) in enumerate(pairs)]

flow = {"_id": "flowCompanion720", "name": "720p companion (in folder)",
        "description": "For every non-h264, >1080p or HDR file, writes a 720p h264 SDR copy with an AAC "
                       "stereo track next to the original as '<name> - 720p.mkv', so Jellyfin shows it as a "
                       "second version. Never touches the original. See ~/server docs/media/TRANSCODING.md.",
        "tags": "", "flowPlugins": nodes, "flowEdges": edges}
print(json.dumps({"data": {"collection": "FlowsJSONDB", "mode": "insert", "docID": flow["_id"], "obj": flow}}))
