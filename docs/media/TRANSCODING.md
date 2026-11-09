# Transcoding

Why Jellyfin transcodes on `pve-prod`, what it costs, and the rule for what
Tdarr is allowed to touch.

Written 2026-09-04 after one playback pushed the load average to 18.75.
Revised 2026-09-10 after Jellyfin 12.0 changed the constraint the first version
was built around. See "What changed on 2026-09-10" below.
Rebuilt 2026-11-03: the companions now live next to the originals as a second
Jellyfin version, and Tdarr runs at the lowest CPU weight. See "Design, as
built on 2026-11-03" below. The sections before it are the measurements that
led there.

## The hardware answer, settled

`pve-prod` cannot do hardware transcode, and no configuration change fixes it.

`lscpu` on `pve-prod` reports 2 sockets of `Intel Xeon E5-2670 @ 2.60GHz`, with
24 vCPUs given to the VM. That is Sandy Bridge-EP from 2012. The E5-2600 family
has no integrated graphics and no Quick Sync. The PowerEdge R720 carries only a
Matrox BMC display chip, which cannot encode video. `/dev/dri` does not exist in
the guest.

So there is no device to pass through. Hardware transcode needs a discrete GPU
bought and fitted to `pve` first. That is blocked on budget, like every
other hardware upgrade here. See `docs/HARDWARE.md`.

Every transcode on this box is software, on a 2012 CPU. Treat CPU time at
playback as the scarce resource.

## What one 4K transcode costs

Measured on 2026-08-31 at 14:29 SAST:

| Metric | Value |
|---|---|
| Load average, 1 minute | 18.75 |
| CPU used by one `ffmpeg` | 1664 percent, about 17 of 24 cores |
| CPU idle | 18.5 percent |
| Memory used | 9.3 GiB of 43 GiB |

The file was
`Silo (2023) - S03E07 - Radio [ATVP][WEBDL-2160p][EAC3 Atmos 5.1][DV HDR10Plus][h265]-playWEB.mkv`.

The command did three expensive things at once: decode 2160p h265, tone map
Dolby Vision and HDR10+ down to bt709 with the `tonemapx` filter, then encode to
`libx264` at `-preset veryfast`.

Memory was never the constraint. CPU was.

## What changed on 2026-09-10

Three findings, recorded because each one invalidates part of the first version
of this document.

### 1. Jellyfin jumped from 10.11 to 12.0 without being asked

`stacks/media/jellyfin/compose.yaml` pins `lscr.io/linuxserver/jellyfin:latest`.
On 2026-09-08 that tag delivered a major version change. `docker inspect`
reports the image was built at `2026-09-08T02:30:49Z` and the container was
recreated at `2026-09-08T13:03:16Z`. The server now logs
`Main: Jellyfin version: 12.0.0`.

An unattended major version jump on the service host is a risk worth naming.
Consider pinning a minor tag.

### 2. Jellyfin 12.0 groups episode versions. 10.11 did not.

**This reverses the central claim of the first version of this document.**

The 12.0 release notes state: "Alternate versions have been a movies-only
feature since they were introduced. In 12.0 they work for episodes as well, so a
series with a broadcast cut and an extended cut, or a 1080p and a 4K copy of the
same episode, can be grouped the way movies always could."

The release notes also say a library rescan is required, because "making
versions work correctly for episodes meant fixing how version links are stored,
and automatically resolved versions have to be rebuilt from the files on disk."

Source: https://jellyfin.org/posts/jellyfin-release-12.0/

The old evidence for the opposite claim (`EpisodeResolver.cs` not implementing
`IMultiItemResolver`, and jellyfin discussion 16063) described the
`release-10.11.z` branch. Discussion 16063 is still open and still says
grouping is unsupported. The release notes are newer and specific. Trust the
release notes.

This does **not** mean the companion file should now be written next to the 4K
episode. See "The one open decision" below.

### 3. Tdarr has never transcoded anything

The Tdarr statistics API on 2026-09-09 reported:

```
"totalFileCount":244, "totalTranscodeCount":0,
"processWarning":"The following libraries have transcodes disabled:\n Jellyfin"
```

`/mnt/data/media/tv-1080p` exists and is empty. Jellyfin has 3 libraries
(`Series`, `Movies`, `Audiobooks`). The second library this document described
was never created. The design below was written but never built.

The single Tdarr library is a stale import from `jjserver`. Its `createdAt` is
`1675837380368`, which is 2023-02-08. Its settings are a loaded footgun:

| Setting | Value | Problem |
|---|---|---|
| `folder` | `/media` | The whole root, with no filter |
| `output` | `.` | Replaces source files in place |
| `folderToFolderConversion` | `false` | No separate output folder |
| `schedule` | all 168 hours checked | Would run during watching hours |
| `preset` | `-Z "Very Fast 1080p30"` | HandBrake path, not ffmpeg |
| `processTranscodes` | `false` | The only reason nothing has broken |

Enabling transcodes on that library replaces files inside `/media/tv` and
`/media/movies`, which breaks rule 3 below. **Delete this library. Do not edit
it.**

## Library composition

`ffprobe` run over all video files under `/data/media/tv` and
`/data/media/movies` on 2026-09-09.

| Attribute | Files |
|---|---|
| Total video files | 244 (236 TV, 8 movies), 0.58 TB |
| Video codec is not h264 | 33 |
| Height above 1080 | 34 |
| **Need a companion for compatibility** | **35** |
| HDR, `smpte2084` transfer | 21 |
| Contain eac3, truehd or dts audio | 145 |
| Contain image subtitles, PGS or VOBSUB | 4 |
| Text subtitles, `subrip` | 192 |

Bitrate: median 6.2 Mb/s, maximum 52.3 Mb/s. 117 files are above 6 Mb/s. 216
files are above 4 Mb/s. Reacher season 1 runs at 45 to 52 Mb/s.

The 35 files are the 33 non-h264 files plus 2 h264 files at 2160p. A browser can
decode h264 at 2160p, but many phone decoders cap h264 at 1080p, and 33 Mb/s is
not streamable remotely. Count both.

### The library has two separate problems

Keep them apart. They need different answers.

1. **Compatibility** affects 35 files. Browsers do not decode HEVC, and no
   browser handles Dolby Vision.
2. **Bandwidth** affects 216 files. No home uplink carries 52 Mb/s.

One 720p companion file answers both at once. See "Design" below.

## Which clients actually fail

Read from `Devices` in `jellyfin.db` and `PlaybackActivity` in
`playback_reporting.db` on 2026-09-04, under Jellyfin 10.11.11. The client
version strings changed with the 12.0 upgrade. The pattern did not.

| Client | Device | Plays HEVC | Notes |
|---|---|---|---|
| Jellyfin for Tizen 1.1.0 | Samsung Smart TV | Native app, expected yes | 10 DirectPlay, 2 audio-only transcode, all on 1080p h264. No 4K play recorded yet. |
| Jellyfin for Android 2.7.2 | Johan's S25 FE | Native app, expected yes | No rows in the reporting window. |
| Jellyfin Web | Firefox on `jj-laptop` | **No** | The confirmed cause of the 4K transcode. |
| Jellyfin Web | Chrome | **No** on Linux | |
| Jellyfin Web | Firefox Android | **No** | |

**Every failing client is a web browser. Every native app direct plays.**

Firefox and Chrome on Linux do not decode HEVC, and no browser handles Dolby
Vision. This is a browser limitation, not a device limitation. `jj-laptop` has
an Intel Meteor Lake-P Arc iGPU and an NVIDIA RTX 500 Ada. It can hardware
decode 2160p HEVC 10-bit on its own without help from the server.

The `playback_reporting` plugin was installed on 2026-08-31, so its window is
short and covers only 12 plays. Do not read an absent device as a working one.

## AV1 is the wrong target for this box

Jellyfin 12.0 added "AV1 direct streaming on TV clients". Two facts make it
useless here.

1. The TV is not the failing client. The table above shows every native app
   direct plays and every failure is a browser. AV1 on TV clients fixes a
   problem this household does not have.
2. `pve-prod` must encode AV1 in software. There is no AV1 encode hardware on a
   2012 Xeon and there is no `/dev/dri`.

Encode H.264 High profile instead. Every browser, phone and TV decodes it in
hardware.

## Design, as built on 2026-11-03: companions next to the originals

Tdarr writes a 720p h264 SDR companion **into the same folder as the
original**. Jellyfin groups the 2 files as 2 versions of one item, and the
player has a version dropdown. There is no separate 720p library.

This replaces the separate-library plan of 2026-09-10. Three reasons:

1. One library. No duplicate titles in search, home and Continue Watching.
2. Deletion works. Maintainerr deletes through Radarr, and Radarr deletes the
   whole movie folder, companion included. A separate library would keep the
   companion as an orphan.
3. Hardlinks were never at risk. Tdarr adds a new file and never rewrites the
   original, so seeding is not affected.

### Companion format

| Property | Value | Reason |
|---|---|---|
| Video | H.264 High, 8-bit, `bt709` SDR, CRF 22 capped at 2.5 Mb/s | Decodes everywhere in hardware |
| Height | 720 (never upscaled) | Enough for a phone or a browser tab |
| HDR source | `tonemapx` bt2390 to bt709 | 43 fps on a 4K HDR10 source, 1.7x real time |
| Audio track 1 | AAC 2.0, 192k, default | Browsers cannot decode eac3, truehd or dts |
| Audio track 2 | First lossy surround track (AC3, EAC3, AAC, ...) of the original, copied. None if there is no such track | Keeps 5.1 for a laptop or soundbar. TrueHD, DTS and FLAC are never copied: copied TrueHD made the Mad Max companion 7.0 GB, and no phone decodes it |
| Subtitles | Text only (SRT, ASS, WebVTT). MP4 `mov_text` becomes SRT. `default` flag removed | MKV cannot hold `mov_text`. Image subtitles (PGS, VobSub) are dropped: on a phone they force a burn-in, which is a full live transcode |
| External subtitles | The original's `.en.srt` etc. copied as `<companion stem>.en.srt` | Jellyfin shows an external subtitle only on the version whose file name it starts with. The Tdarr flow copies them when it writes the companion. Bazarr runs `stacks/media/scripts/companion-subs.py` as post-processing for later downloads and upgrades |
| Stream tags | mkvmerge statistics tags (`BPS`, `NUMBER_OF_BYTES`, ...) deleted | The copied values describe the original. The Mad Max companion said 20 Mb/s video |

Changed on 2026-11-09 (audio track 2, subtitles, tags). The 56 companions
made before that date were remuxed to the new rules with a stream copy, no new
encode. The Parasite test: Jellyfin listed the English SRT on the 720p version
only after a copy named after the companion was added.

### Names

| Kind | Original | Companion |
|---|---|---|
| Movie | `<folder>/<folder> - [Bluray-2160p]...mkv` | `<folder>/<folder> - 720p.mkv` |
| Episode | `Show (2020) - S01E01 - Title [...].mkv` | `Show (2020) - S01E01 - 720p.mkv` |

Jellyfin 12.4 labels the companion version `720p`. Both names stay the same
when Radarr or Sonarr upgrades the original, so a new companion overwrites the
old one. A double episode keeps its token, `S01E01-E02`.

### What was tested on 2026-11-03

- **Jellyfin grouping, episodes.** Two Arrested Development S05 episodes, one
  per name pattern. After a series refresh each episode was 1 item with 2
  MediaSources, the second named `720p`. No extra episode item appeared.
- **Sonarr.** A `RescanSeries` left the episode files unchanged (84 files,
  same ids, same paths). Sonarr did not import, rename or delete the
  companions.
- **Radarr.** Frankenweenie got the first flow-made companion. A
  `RescanMovie` left Radarr tracking only movie file 23, the original. The
  companion was not imported, renamed or deleted. After a refresh Jellyfin
  showed 1 movie with 2 MediaSources, the second named `720p`.
- **Jellyfin pickup.** About 2 minutes after the Frankenweenie companion was
  written, Jellyfin still showed 1 version. A manual item refresh was needed.
  Not yet known: whether the realtime monitor picks it up later, or only the
  12-hourly "Scan Media Library" task does.
- **Delete cleanup.** `DELETE /episodefile/191` in Sonarr ran
  `companion-cleanup.sh`, which removed the S05E07 companion and left S05E14.

### Which version a client starts

jellyfin-web `playbackmanager.js`, `getOptimalMediaSource`: "Prefer the played
item's own source, transcoding it if needed, over another version". So every
web-based client starts the original: Jellyfin Web, the Samsung Tizen app and
the Android app (both wrap jellyfin-web). On the TV and the phone that is
correct, they direct play it. **In a browser, pick `720p` in the version
dropdown**, or the server transcodes the 4K original.

`jj-laptop` runs Jellyfin Desktop (Flatpak `org.jellyfin.JellyfinDesktop`).
It plays the 4K original directly on the laptop GPU and needs no companion.

A PlaybackInfo call with a hand-made browser DeviceProfile is not a valid
test of this. On 2026-11-03 the server marked MKV sources direct-playable for
a profile that allowed only mp4 and webm.

## How it is built

### Tdarr

| Object | Id | Notes |
|---|---|---|
| Flow | `flowCompanion720` | One flow for both libraries. Source: `stacks/media/tdarr/flows/build_flow.py` |
| Library | `libMovies720` | Folder `/media/movies` |
| Library | `libTv720` | Folder `/media/tv` |
| Node limits | 2 transcode CPU workers | Schedule: all 168 hours |

Flow path: skip a file whose name ends in ` - 720p.mkv`. If the file is h264,
at most 1080p and SDR, no companion is needed: delete a stale companion if one
exists. Otherwise encode (HDR path tone maps), copy the result next to the
original, and set the working file back to the original. The flow never uses
"Replace Original File".

Two Tdarr API traps, both measured on 2026-11-03:

1. The worker reads the library's **top-level** `flowId`. Setting only
   `decisionMaker.flowId` gives `No plugins or edges for library selected
   flowId:` and a transcode error.
2. Tdarr links each file record to one library. A library that covers the
   same folder keeps the records. The stale `Jellyfin` library (`/media`) had
   to be deleted, and the records moved with a `FileJSONDB` update of `DB`.

The flow writes the companion with copy-then-rename. `/temp` and `/media` are
separate bind mounts, so `rename()` from the cache gives `EXDEV`.

### CPU priority

`stacks/media/tdarr/compose.yaml` sets `cpu_shares: 2`, which Docker maps to
cgroup v2 `cpu.weight` 1 against 100 for every other container. Tdarr only
uses idle CPU, so Jellyfin always wins and Tdarr may run at every hour.
`nice` inside the container would not work: with cgroup v2 it only ranks
processes in the same cgroup.

### Cleanup when an original is deleted

`stacks/media/scripts/companion-cleanup.sh` is mounted read-only at
`/scripts` in Sonarr and Radarr. A "Custom Script" connection named "Delete
720p companion" runs it on file delete and on delete for upgrade. It removes
the companion with the same name rule as the flow. Sonarr sets the variables
as `Sonarr_EpisodeFile_Path`, so the script matches them case-insensitively.

## Two things still force a live transcode

A correct companion file is not sufficient on its own. Both of these override it.

1. **The Jellyfin per-user remote bitrate limit.** If a user policy caps remote
   streaming below the file bitrate, Jellyfin transcodes even when the codec is
   correct. Check `Dashboard > Users > <user> > Playback`.
2. **The client quality setting.** A client set to anything except `Auto` or the
   maximum requests a lower bitrate, and Jellyfin transcodes to reach it.

## Trickplay extraction is a second full-library decode

`/mnt/docker-data/appdata/jellyfin/data/root/default/Series/options.xml` sets
both `EnableTrickplayImageExtraction` and
`ExtractTrickplayImagesDuringLibraryScan` to `true`. Trickplay extraction
decodes the whole file.

On 2026-09-09 that ran at the same time as an Intro Skipper library scan. Two
full-library `ffmpeg` passes took the `pve` load average to 19.01 and the
`pve-prod` load average to 31.49.

Status on 2026-11-03: extraction during scan is still on, and it stays on. The
scheduled tasks "Generate Trickplay Images" and "Extract Chapter Images" fire
at 03:00 and 02:00, when `pve-prod` is powered off, so with extraction off
during the scan no trickplay would ever be made. The risk is smaller now:
`TrickplayOptions` use `ProcessPriority` `BelowNormal`, 4 threads and
keyframe-only extraction. That runs inside the jellyfin container, so
`BelowNormal` does rank it below a playback `ffmpeg`. Jellyfin also makes
trickplay for each companion version, a `<name> - 720p.trickplay` folder.

## Clients

`jj-laptop` has Jellyfin Desktop 2.0.0 (Flatpak
`org.jellyfin.JellyfinDesktop`, the successor of Jellyfin Media Player). It is
mpv-based and direct plays HEVC, HDR and DV with the Arc iGPU, so the server
does no work for that machine. Use it instead of Firefox.

The Samsung TV (Tizen) and the Android phone direct play the originals. The
companions are for browsers: Firefox Android, guests, and any laptop session
in a browser.
