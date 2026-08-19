# Jellyfin streaming test protocol

The question: what does a stream from `pve-prod` cost, and how does the TV
differ from the phone?

Run `scripts/jellyfin-stream-bench.sh <label>` once per row of the matrix.

## The thing that decides the answer

Source resolution does not set the cost. `PlayMethod` does.

| PlayMethod | Server CPU | Network carries |
|---|---|---|
| DirectPlay | near zero | the full source bitrate |
| DirectStream | near zero | the full video bitrate |
| Transcode | high | the target bitrate, usually lower |

Three things together choose the method: the source codec, the client decoder,
and the client quality setting. A 4K file can be free on the TV and expensive
on the phone, and the same 4K file can be free on the phone too if you raise
its quality setting. So the quality setting is a controlled variable, not
something to leave on whatever it was.

`pve-prod` has no `/dev/dri` passthrough, so every transcode is libx264 on the
R720 CPUs. See the comment in `stacks/media/jellyfin/compose.yaml`. The CPUs
are two Intel Xeon E5-2670, and the VM gets 24 vCPU.

## The files

Chosen by `ffprobe` on 2026-08-19 out of what the library holds. The first two
match on bitrate, framerate and audio, so resolution and video codec are the
only things that change between them.

| Role | File | Video | Audio | Rate |
|---|---|---|---|---|
| 4K | `Silo (2023) - S03E01 - Who Are You ...h265-TheBlackKing.mkv` | hevc Main 8-bit SDR, 3840x1606, 23.976 fps | EAC3 5.1 | 10.0 Mbit/s |
| 1080p | `Common Side Effects (2025) - S01E09 - Cliffs Edge ...h264-FLUX.mkv` | h264 High, 1920x1080, 23.976 fps | EAC3 5.1 | 10.3 Mbit/s |
| 4K stress | `Silo (2023) - S03E07 - Radio ...[DV HDR10Plus][h265]-playWEB.mkv` | hevc Main 10, HDR10+ and Dolby Vision, 3840x1606 | EAC3 5.1 | 24.8 Mbit/s |

Two honest limits on these files:

1. Both Silo files are 3840x1606, not 3840x2160. They are letterboxed at
   2.40:1, so they hold about 25 percent fewer pixels than a full-height UHD
   file. A transcode of a full-height 2160p file will cost more than what
   these runs report.
2. The 4K file runs at 10.0 Mbit/s, which is low for 4K. It was picked to
   match the 1080p file, so the network load is held constant on purpose. It
   does not represent what a typical 4K file costs the WiFi. The 4K stress
   file answers that question instead.

## Hold these constant

1. Use the same two files for every run. One 4K file, one 1080p file.
2. Start each run at the same point in the file, not at 0:00. Use 10:00.
   Opening credits are cheap to encode and are not representative.
3. Put the TV and the phone on the same 5 GHz SSID (`jjlink`, channel 36).
   Do not let the phone sit on 2.4 GHz.
4. Do not move either device between runs.
5. Pause Tdarr before you start. Tdarr transcodes on the same CPUs and will
   corrupt every server-load number. It was already in the docker `Paused`
   state on 2026-08-19.
6. Pause qBittorrent. It competes for disk and for the uplink. It was also
   already paused on 2026-08-19.
7. Play one stream at a time, except for run C1.
8. Check the idle percentage with `vmstat 2 3`, not the load average. After a
   boot the load average stays high for a long time because of I/O wait, and
   it reads as busy when the CPUs are not. On 2026-08-19 the load average was
   6.32 while `vmstat` reported 96 percent idle. Start the runs when idle is
   above 90 percent.

## Pass A — what each client does on its own

Set the quality on both clients to **Auto** or **Maximum**. Then any transcode
is caused by the client decoder, not by a bitrate cap you set.

| Label | Device | File |
|---|---|---|
| `tv-4k` | TV | 4K |
| `phone-4k` | phone | 4K |
| `tv-1080p` | TV | 1080p |
| `phone-1080p` | phone | 1080p |
| `tv-4k-stress` | TV | 4K stress |
| `phone-4k-stress` | phone | 4K stress |

Six runs of three minutes each. About 30 minutes with setup.

The last two rows carry Dolby Vision and HDR10+. Many clients cannot decode
Dolby Vision and will transcode where they direct-played the plain 4K file.
That is the point of those two runs, so keep them separate from the first
four rather than reading all six as one series.

## Pass B — same server work, different client

Optional. Set both clients to a fixed **1080p / 8 Mbps** cap, then play the 4K
file. Both clients now force a transcode, so the server work is equal and the
only difference left is the client and its WiFi link.

| Label | Device | File |
|---|---|---|
| `tv-4k-capped` | TV | 4K |
| `phone-4k-capped` | phone | 4K |

## Pass C — contention

Optional, one run. Start the 4K file on the TV, then start the same file on
the phone about 15 seconds later.

| Label | Device | File |
|---|---|---|
| `c1-both-4k` | TV and phone together | 4K |

Run the script twice, once per device, using `-D` to lock each instance onto
the right session:

    scripts/jellyfin-stream-bench.sh -D "<tv device name>" c1-both-4k-tv &
    scripts/jellyfin-stream-bench.sh -D "<phone device name>" c1-both-4k-phone

The number to watch here is the encode framerate. Two software transcodes on
the same CPUs will drop the realtime factor of both.

## Reading a report

- **realtime factor under 1.00x** means the transcoder cannot keep up. The
  client will stall. This is the single most important number.
- **stalled samples above 0** means playback actually paused to rebuffer.
- **mean tx** is what the WiFi has to carry. Compare it against the numbers in
  `docs/network/after-ax10.txt`.

## Compare the runs

    scripts/jellyfin-stream-compare.sh
