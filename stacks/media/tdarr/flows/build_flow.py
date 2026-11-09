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
const done = (args, n) => ({ outputFileObj: args.inputFileObj, outputNumber: n, variables: args.variables });
"""

GUARD = HELPER + r"""
module.exports = async (args) => {
  // Output 2 ends the flow: never make a companion of a companion.
  if (isCompanion(args.originalLibraryFile._id)) { args.jobLog('Companion file, skipping'); return done(args, 2); }
  // Subtitle codec per stream, read by the encode step as subArgs. MKV
  // cannot hold MP4 mov_text subtitles (ffmpeg: "Subtitle codec 94213 is not
  // supported", 6 Peep Show episodes failed 2026-11-04), so convert those to
  // SRT. Copy every other subtitle stream as it is.
  const subs = ((args.inputFileObj.ffProbeData || {}).streams || []).filter((s) => s.codec_type === 'subtitle');
  let subArgs = '-c:s copy';
  subs.forEach((s, i) => { if (s.codec_name === 'mov_text') subArgs += ' -c:s:' + i + ' srt'; });
  args.variables.user = Object.assign({}, args.variables.user, { subArgs });
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
  return done(args, 1);
};
"""

REMOVE = HELPER + r"""
module.exports = async (args) => {
  // The original no longer needs a companion (e.g. upgraded to h264 1080p
  // SDR). Remove a stale one so Jellyfin stops offering it.
  const orig = args.originalLibraryFile._id;
  const dst = companionOf(orig);
  if (dst !== orig && fs.existsSync(dst)) { fs.unlinkSync(dst); args.jobLog('Removed stale companion ' + dst); }
  return done(args, 1);
};
"""

COMMON_IN = '-hide_banner -i "{{{args.inputFileObj._id}}}" -map 0:v:0 -map 0:a:0 -map 0:a:0 -map 0:s?'
COMMON_OUT = (
    '-c:v libx264 -preset medium -profile:v high -crf 22 -maxrate 2500k -bufsize 5000k '
    '-c:a:0 aac -ac:a:0 2 -b:a:0 192k -c:a:1 copy {{{args.variables.user.subArgs}}} '
    '-disposition:a:0 default -disposition:a:1 0 -disposition:s -default -map_chapters 0 '
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
