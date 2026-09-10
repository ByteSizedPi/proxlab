# Transcoding

Why Jellyfin transcodes on `pve-prod`, what it costs, and the rule for what
Tdarr is allowed to touch.

Written 2026-09-04 after one playback pushed the load average to 18.75.
Revised 2026-09-10 after Jellyfin 12.0 changed the constraint the first version
was built around. See "What changed on 2026-09-10" below.

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

## Design: one 720p companion tier

Build one companion tier, not two. A single 720p H.264 file answers
compatibility and bandwidth together.

| Property | Value | Reason |
|---|---|---|
| Video | H.264 High, 8-bit, `bt709` SDR | Decodes everywhere in hardware |
| Height | 720 | Enough for a phone. Cuts bitrate hard |
| Bitrate | 2.5 Mb/s target | Survives a weak uplink |
| Audio track 1 | AAC 2.0 stereo, default | Browsers cannot decode eac3 or dts |
| Audio track 2 | Original, copied | The TV keeps 5.1 |
| Subtitles | Copy `subrip` only | Text subtitles direct play |
| Container | MKV | Matches the originals |

The AAC track matters for 145 of 244 files. Without it a browser triggers
audio-only transcode. Audio-only transcode costs a few percent CPU, not 1700
percent, so it is not urgent. Add the track anyway, because it is free at
encode time.

Image subtitles are the hidden trap. Burning in a PGS subtitle forces a full
video transcode even when the video codec is already correct. Only 4 files carry
them, so the cost is small.

Expect 25 to 30 hours of encode time for all 244 files. The 21 HDR files are the
slow ones, because tone mapping runs on CPU.

## The one open decision

Jellyfin 12.0 can group episode versions, but grouping needs both files in one
folder:

```
Silo (2023) {tvdb-000}/Season 03/
├── Silo (2023) - S03E07 - Radio [...].mkv
└── Silo (2023) - S03E07 - Radio [...] - 720p.mkv
```

That folder is a Sonarr root. Sonarr's periodic series rescan parses filenames.
Sonarr can attach the companion to the episode and then treat the original as
unneeded. **This behaviour has not been tested on this setup.**

**Decision for now: keep Tdarr out of the Sonarr and Radarr roots.** Write to
`/media/tv-720p` and `/media/movies-720p`, and add a second Jellyfin library.

The split library costs the version dropdown. It buys two things back:

1. Nothing can delete a 4K original.
2. Jellyfin library access is per user. Household members can be given the 720p
   library only, so they never pick the wrong file and never start a transcode.
   `jj` keeps both.

Test version grouping on one series later, after the companions exist. The test
is reversible then, because the originals are untouched.

## The scope rule for Tdarr

Tdarr replaces files by default. That behavior is for normalizing a whole
library, and it is the wrong behavior here.

1. **Never queue a whole-library pass in one go.** Run the 35 incompatible files
   first, confirm one plays in Firefox, then add the rest in batches.
   `pve-prod` is powered off nightly, so a long queue runs during the hours the
   box is used for watching.
2. **Scope every Tdarr library by a filter**, not by a folder alone. The first
   filter is: video height above 1080, or video codec is `hevc`.
3. **Never let Tdarr write into `/media/tv` or `/media/movies`.** Sonarr and
   Radarr own those paths. A file Tdarr replaces there loses its hardlink to
   `/mnt/data/torrents`, which breaks seeding, and the *arr apps will treat the
   changed file as an upgrade candidate.
4. **Use a Tdarr Flow, not the classic plugin stack.** A Flow sets the output
   path explicitly and leaves the source untouched. The classic path in the
   stale library wrote in place.

## Layout

```
/mnt/data/
├── transcode/            Tdarr scratch, /temp in the container
└── media/
    ├── movies/           Radarr root. Never written by Tdarr.
    ├── movies-720p/      Tdarr output. A second Jellyfin library.
    ├── tv/               Sonarr root. Never written by Tdarr.
    └── tv-720p/          Tdarr output. A second Jellyfin library.
```

`/mnt/data/media/tv-1080p` is the empty folder from the first version of this
design. Remove it, or rename it to `tv-720p`.

`transcode/` is on `DATA_ROOT`, not `CONFIG_ROOT`, and this matters twice.

First, `CONFIG_ROOT` is `/dev/sda1`, the 63 GB VM root disk. It sat at 87
percent used with 8.5 GB free on 2026-08-31. One 2160p scratch file is larger
than that, so a transcode there fills the root filesystem and takes the OS with
it. The original `stacks/media/tdarr/compose.yaml` mounted `/temp` there.

The fix was WRITTEN on 2026-09-04 but sat uncommitted in the working tree until
commit `1c29830` on 2026-09-10. The running container used the root-disk path
for those 6 days. Tdarr ran no job in that window, so nothing filled the disk.

The root filesystem did fill on 2026-09-10, to 98 percent, and Jellyfin
crash-looped. The cause was old Docker images, not transcode scratch. Commit
`e1509c3` adds a daily prune procedure, because Komodo Core's own `auto_prune`
fires at UTC midnight, when `pve-prod` is powered off.

Second, `transcode/` and `media/` are on the same filesystem, `/dev/sdc`. Tdarr
finishes a job by moving the output into place. On one filesystem that is a
rename. Across two it is a copy of several GB.

## Build steps

1. Delete the Tdarr library named `Jellyfin`. Do not edit it.
2. Create `/mnt/data/media/tv-720p` and `/mnt/data/media/movies-720p`, owned by
   `${PUID}:${PGID}`.
3. Create a Tdarr Flow that writes the format in the Design table above.
4. Create a Tdarr library on `/media/tv`, with the Flow attached and output set
   to `/media/tv-720p`. Repeat for `/media/movies`.
5. Set the Tdarr schedule to the hours nobody watches.
6. Queue the 35 incompatible files first. Filter on codec `hevc` or height above
   1080. Confirm one output file direct plays in Firefox before queuing more.
7. Add the rest of the library in batches.
8. Add `/media/tv-720p` and `/media/movies-720p` as Jellyfin libraries named
   `TV (720p)` and `Movies (720p)`.

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
`pve-prod` load average to 31.49. Turn extraction off during the library scan
and run it as a scheduled task instead.

## The cheaper fix, which is not exclusive with the above

Install a native Jellyfin client on `jj-laptop`. Jellyfin Media Player is
mpv-based and direct plays HEVC and DV using the Arc iGPU. Server CPU drops to
near zero and no companion file is needed for that machine. `mpv` and `vlc` are
already installed there. Jellyfin Media Player is not.

This does not replace the companion library, because Firefox Android and guest
browsers stay in the picture. It does remove the largest single source of
transcodes today.
