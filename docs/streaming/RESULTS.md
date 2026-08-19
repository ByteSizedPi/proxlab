# Jellyfin streaming results, 2026-08-19

Six runs of 180 s each, captured with `scripts/jellyfin-stream-bench.sh`.
Server was `pve-prod` on the R720, two Xeon E5-2670, 24 vCPU, 96 percent idle
at the start. Tdarr and qBittorrent were both in the docker `Paused` state.

| Run | File | Method | CPU mean | CPU peak | Wire rate | Stalls |
|---|---|---|---|---|---|---|
| `phone-4k` | Silo S03E01, 10.0 Mbit/s | DirectPlay | 11.8% | 41.4% | 11.2 Mbit/s | 0 |
| `tv-4k` | Silo S03E01, 10.0 Mbit/s | remux | 31.5% | 78.6% | 10.4 Mbit/s | 0 |
| `tv-1080p` | Common Side Effects S01E09, 10.3 Mbit/s | DirectPlay | 12.5% | 39.7% | 10.6 Mbit/s | 0 |
| `phone-1080p` | Common Side Effects S01E09, 10.3 Mbit/s | DirectPlay | 13.2% | 40.1% | 10.9 Mbit/s | 0 |
| `tv-4k-stress` | Silo S03E07, 24.8 Mbit/s DV | DirectPlay | 17.1% | 35.7% | 26.0 Mbit/s | 0 |
| `phone-4k-stress` | Silo S03E07, 24.8 Mbit/s DV | DirectPlay | 15.3% | 35.4% | 24.4 Mbit/s | 0 |

CPU percentages are of one core. The VM has 24, so the worst run used about
3 percent of the machine.

## What the numbers say

1. **The R720 never encoded a single frame.** Five runs were DirectPlay and one
   was a container remux. No run needed the CPU for video.
2. **Wire rate tracks source bitrate and nothing else.** The 10 Mbit/s files
   moved 10.4 to 11.2 Mbit/s. The 24.8 Mbit/s file moved 24.4 to 26.0 Mbit/s.
   The overhead is a few percent.
3. **TV and phone cost the same.** Every DirectPlay run sat between 11.8 and
   17.1 percent of one core, whichever device asked for it. The phone was
   marginally cheaper than the TV on both 4K files.
4. **Resolution did not matter.** 4K and 1080p produced the same server load,
   because both clients decode HEVC and h264 in hardware.
5. **Nothing stalled.** The WiFi carried 26 Mbit/s to the TV without one
   dropped sample.

## The one outlier, and its real cause

`tv-4k` cost 31.5 percent, about 2.5 times every other run. Resolution is not
the cause. The two TV runs isolate it:

| TV run | Audio tracks in the file | Method | CPU |
|---|---|---|---|
| `tv-4k` | 2 x EAC3 6ch | remux | 31.5% |
| `tv-1080p` | 1 x EAC3 6ch | DirectPlay | 12.5% |

Jellyfin gave the reason as `SecondaryAudioNotSupported`. The Tizen app refuses
a file with a second audio track, so Jellyfin repackages MKV into HLS to drop
it. The encoder command line confirms no encoding happens:

    -codec:v:0 copy  -codec:a:0 copy  -f hls
    -map 0:0 -map 0:2 -map -0:s

Video copied, audio copied, subtitles dropped. Only the container changes.

**Action:** strip duplicate audio tracks from the library and the only server
cost measured in this experiment goes away. Tdarr can do this.

## A prediction that was wrong

Before the runs I predicted the Samsung TV would transcode the Dolby Vision
file, because Samsung backs HDR10+ and not Dolby Vision. The TV direct-played
it. The file is Dolby Vision **Profile 8.1**:

    dvProfile=8  blCompat=1  type=DOVIWithHDR10Plus

Profile 8.1 carries an HDR10-compatible base layer, so a display without Dolby
Vision plays the base layer and ignores the enhancement layer. Profile 5 has no
compatible base layer and would have forced a transcode. Check the profile, not
the brand.

## What this experiment did NOT measure

State these before using the numbers to justify anything.

1. **The cost of a real transcode is still unknown.** Nothing triggered one, so
   there is no evidence here about what software encoding costs on an E5-2670.
   Do not conclude that hardware transcode passthrough is unnecessary. Conclude
   only that these two clients on these files never asked for it.
2. **Concurrency was never tested.** Every run was a single stream. Two
   simultaneous streams were not measured.
3. **Both 4K files are 3840x1606, not 3840x2160.** They are letterboxed at
   2.40:1 and hold about 25 percent fewer pixels than full-height UHD.
4. **Every run was on the LAN.** Remote streaming over the tailnet or through
   Cloudflare was not tested, and a remote client is the case most likely to
   apply a bitrate cap and force a transcode.
5. **The 4K and 1080p files were chosen to have matching bitrates** (10.0 and
   10.3 Mbit/s). Their equal wire rates are by construction, not a finding.

## Side finding: Jellyfin cannot see client IP addresses

Every session reported `RemoteEndPoint` as `172.22.0.8`, which is the Traefik
container, not the TV or the phone. Jellyfin sees all traffic as coming from
one proxy address. Access logs cannot identify a device, and any policy that
depends on the client address cannot work. Fixing this needs Jellyfin to trust
the proxy and read the forwarded header. It did not affect these results,
because a private source address is treated as local either way.

## What was changed as a result, 2026-08-19

### Jellyfin now sees real client addresses

`KnownProxies` was empty, so Jellyfin used the socket peer address and logged
every session as `172.22.0.8`. Set `KnownProxies = ["traefik"]` and
`LocalNetworkSubnets` to the four real subnets, then restarted the container.
Verified: a session from the laptop now reports `10.42.0.145`. The reasoning,
including why `LocalNetworkSubnets` must be set in the same change, is in
`stacks/media/jellyfin/compose.yaml`.

### Three files remuxed to English-only audio

The conclusion above said the 4K files carried "duplicate" audio tracks. That
was wrong. An audit of all 135 library files found only **3** with a second
audio track, and in each the first track is **Italian** and the second is
English:

| File | Track 1 | Track 2 |
|---|---|---|
| Silo S03E01 | Italian EAC3 Atmos 5.1 | English EAC3 Atmos 5.1 |
| Silo S03E04 | Italian EAC3 Atmos 5.1 | English EAC3 Atmos 5.1 |
| Rick and Morty S09E09 | Italian EAC3 256 kbps | English EAC3 640 kbps |

So the Tizen remux was Jellyfin selecting the English track (`-map 0:2`)
correctly, not wasted work.

All three were remuxed with `ffmpeg -c copy`, keeping video, English audio,
every subtitle and every chapter. Durations are unchanged. Ownership stayed
`jj:jj 644`. Each file dropped from 2 hardlinks to 1, because the rewrite
breaks the link to `/mnt/data/torrents` — the original is still there, seeding
is unaffected, and the change is reversible from that copy. Disk went from
246 GB to 253 GB.

A library-wide Tdarr plugin stack was rejected as disproportionate for 3 files
out of 135.

### Root cause is sourcing, not the files

`TheBlackKing` and `MeM` are Italian release groups. Their raw release names
declare both languages:

    Silo.S03E01.Who.Are.You.2160p.ATVP.WEB-DL.DDP5.1.ENG.ITA.Atmos.SDR.H265-TheBlackKing

The Recyclarr config already applies `Language: Not English` at -10000. It did
not fire, and it was right not to: these releases DO contain English audio.
`Language: Not English` rejects a release with no English track, not a
dual-audio one. Sonarr's file renaming drops the language tags, which is why
the names on disk look as though they never declared a language.

The fix belongs in a Sonarr **Release Profile**, not a Custom Format.
`recyclarr.yml` sets `reset_unmatched_scores: enabled: true` on both managed
profiles, so a hand-added Custom Format would have its score reset to 0 on the
next nightly run. Release Profiles are outside Recyclarr's scope.

Release Profile id 1, "Block Italian dual-audio releases", ignores three
anchored regex terms:

    /\bITA\b/
    /-TheBlackKing\b/
    /-MeM\b/

The `ITA` term does the real work. A release-group blocklist was tried first
and proved inadequate: of 168 releases in one Silo season 3 search, 61 carried
Italian audio but only 22 matched the two group patterns. The other 39 came
from `MeM.GP` and `MeM GP` (dot or space separated, so `-MeM` never matches),
`TBK` (TheBlackKing abbreviated) and `G66` (a different Italian group). Group
names are not a stable signal. The language token is.

The group terms are kept as backup, at no cost.

Every term is regex, not a substring, and that is load-bearing:

- A plain `MeM` term matches "Memory". Silo S03E05 is titled exactly that.
- A plain `ITA` term matches "La Dolce Vita", "Vita and Virginia", "Capital"
  and "Hospital". `\bITA\b` allows all four.

Both patterns were tested against a title list before going live, then verified
with a live season search: 18 of 18 Italian releases rejected, none missed, and
no non-Italian release caught. The one accepted false-positive case is a title
where "Ita" is a genuine standalone word.

## The obvious next experiment

Pass B in `PROTOCOL.md` was never run. Set both clients to a fixed 1080p and
8 Mbit/s cap, then play the 4K file. That forces a real transcode on purpose
and is the only way to answer the question this pass could not: what does
software encoding cost on this hardware, and does it keep up with realtime.
