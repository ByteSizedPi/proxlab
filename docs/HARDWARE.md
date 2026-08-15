# Hardware notes: pve (PowerEdge R720)

Host `pve` at `10.42.0.10`. Changes made outside the Komodo stacks go here.

## 2026-08-05 — loud fans traced to two dead iDRAC temperature sensors

### Symptom

The fans went loud with no warning. Jellyfin was the suspect, because a
trickplay job was running in `pve-prod` at the time. Jellyfin was not the
cause.

### Measurements

Nothing in either OS explained the noise:

| Sensor | Reading |
|---|---|
| CPU package 0 | 33 C |
| CPU package 1 | 45 C |
| Drives 0 and 1 (behind the PERC) | 24 C and 23 C, trip point 60 C |
| I350 NIC | 40 C |
| System draw | 158 W |
| `pve` load average | 1.58 |

The IPMI side told a different story:

```
Fan1  8280 RPM    Fan4  8760 RPM
Fan2  8160 RPM    Fan5  9960 RPM
Fan3  8280 RPM    Fan6  9840 RPM

Inlet Temp   04h | ok | 7.1 | 14 degrees C
Exhaust Temp 01h | ok | 7.1 | 21 degrees C
Temp         0Eh | ns | 3.1 | No Reading
Temp         0Fh | ns | 3.2 | No Reading
```

### Cause

Sensors `0Eh` and `0Fh` are the two processor temperature sensors, entity
`3.1` and `3.2`. Both report `No Reading`. iDRAC has lost its PECI path to the
CPU thermal sensors, and with no CPU temperature to work from it fails safe and
drives the fans hard.

The CPUs themselves are fine. The Linux `coretemp` driver reads the on-die
sensors without trouble (33 C and 45 C above). Only the BMC's reading path is
broken.

A 14 C inlet against a 21 C exhaust is a 7 C rise. The chassis is heavily
overcooled for the load it carries.

### Second finding: PSU 2 has no mains

```
Status         62h | ok | 10.1 | Presence detected
Status         63h | ok | 10.2 | Presence detected, Power Supply AC lost
PS Redundancy  74h | ns |  7.1 | No Reading
```

PSU 2 is seated but has no AC, so the machine has no PSU redundancy. The System
Event Log shows `Power Supply AC lost` asserting on most days since 27 June
2026, at times spread across the day (05:11, 08:38, 13:19, 16:32, 17:43). The
most recent assertion is 08:36:20 on 5 August 2026, which is the same second
the host booted.

I have not established whether the repeated AC loss is load shedding, a failed
PSU, or a loose cable.

**Update after the iDRAC reset:** the `AC lost` flag on PSU 2 cleared and did
not return. It was stale BMC state, not a live power fault. `PS Redundancy`
still reads `No Reading`. No new SEL entry has appeared since 08:36:20 on
5 August 2026.

### Outcome of the iDRAC cold reset, 2026-08-05

`ipmitool mc reset cold` did **not** fix the processor sensors. After the BMC
finished its sensor scan:

```
Inlet Temp   04h | ok | 7.1 | 14 degrees C     (recovered)
Exhaust Temp 01h | ok | 7.1 | 21 degrees C     (recovered)
Temp         0Eh | ns | 3.1 | No Reading       (still dead)
Temp         0Fh | ns | 3.2 | No Reading       (still dead)

Fan1 9960 RPM   Fan2 9720 RPM   Fan3 9840 RPM
Fan4 9480 RPM   Fan5 9840 RPM   Fan6 9840 RPM
```

The fans got **louder**, not quieter. They were 8160-9960 RPM before the reset
and are 9480-9960 RPM after it. All six now sit near the top of their range.

Linux `coretemp` still reads the CPUs without trouble, at 33 C and 43 C, so the
processors and their on-die sensors remain healthy. Only iDRAC's PECI path is
broken.

iDRAC firmware is 2.65, which is the last release for iDRAC7. There is no
firmware update to apply.

Both processor sensors failing at the same moment points at iDRAC rather than
at the CPUs. The trigger was the unclean power-loss reboot at 08:36:20.

**Next thing to try: a full AC power drain.** A BMC cold reset leaves the BMC
powered, so it does not clear all latched state. Shut the host down, unplug
both PSU cables, hold the power button for 30 seconds to drain flea power, wait
a minute, then reconnect. This clears state that `mc reset cold` cannot. It
fits the existing nightly shutdown.

### RESOLVED by the power drain, 2026-08-06

The drain worked. The host came back up at 10:04:58 and both processor sensors
report again:

```
Temp 0Eh | ok | 3.1 | 37 degrees C     was: No Reading
Temp 0Fh | ok | 3.2 | 37 degrees C     was: No Reading
```

iDRAC's readings now agree with what Linux `coretemp` sees independently
(36 C and 37 C), so the PECI path is genuinely correct rather than returning
filler values.

Fan speeds under restored automatic control, measured 4 minutes after boot:

| | Broken | Fixed |
|---|---|---|
| Fan1 | 9960 RPM | 3360 RPM |
| Fan2 | 9720 RPM | 3240 RPM |
| Fan3 | 9840 RPM | 3240 RPM |
| Fan4 | 9600 RPM | 3840 RPM |
| Fan5 | 9960 RPM | 5040 RPM |
| Fan6 | 9840 RPM | 4920 RPM |

Fans 5 and 6 sitting higher than 1 to 4 is normal asymmetry on this chassis.

Manual fan control was cleared by the power cycle. `ipmitool raw 0x30 0x30 0x01
0x01` was run afterwards to confirm automatic mode explicitly.

**The recipe, for next time.** If the fans go loud after an unclean power loss,
check `ipmitool sdr type temperature` for `0Eh` and `0Fh` reading `No Reading`.
`ipmitool mc reset cold` does **not** fix it and made the fans louder. A full AC
drain does. The BMC needs about 3 to 5 minutes after boot to repopulate its
sensor scan, and reading it earlier shows `No Reading` on everything, which
looks like failure but is not.

### Still outstanding: PSU 2 has no cable

The second cable was not connected during the drain. `AC lost` re-asserted at
09:56:31 on 6 August 2026 when power was restored, and `PS Redundancy` still
reads `No Reading`. The machine runs on one supply. The second supply is
present in bay 10.2 and needs only a C13 cable.

## Change log

### ipmitool installed on `pve`, 2026-08-05

```
apt-get install -y ipmitool
```

Pulled in `openipmi` and `libsnmp40t64`. `ipmievd.service` was left disabled.

Installed because `pve` has `/dev/ipmi0` and a detected BMC but had no IPMI
userspace tool, so the fan speeds and the System Event Log could not be read.

To remove: `apt purge ipmitool openipmi`.

### Manual fan control set to 20%, 2026-08-05 16:20 SAST

**This is a temporary measure and it is currently active.**

```
ipmitool raw 0x30 0x30 0x01 0x00        # take manual control
ipmitool raw 0x30 0x30 0x02 0xff 0x14   # all fans to 20%
```

Result, measured right after:

| | Before | After |
|---|---|---|
| Fan1 | 9960 RPM | 5040 RPM |
| Fan2 | 9720 RPM | 4800 RPM |
| Fan3 | 9840 RPM | 4920 RPM |
| Fan4 | 9600 RPM | 4680 RPM |
| Fan5 | 9960 RPM | 5040 RPM |
| Fan6 | 9840 RPM | 5040 RPM |

The fans keep spooling down for a few minutes after the command. They settled
at about 3300 RPM, roughly a third of where they started.

CPU package 1 rose from 45 C to 48 C on the reduced airflow and held there.
Package 0 stayed at 34 C. Inlet 14 C, exhaust 21 C.

**The thermal safety net is off.** Sensors `0Eh` and `0Fh` are still dead, so
iDRAC has no CPU temperature and cannot raise the fans if a processor heats up.
Watch `coretemp` through the OS instead:

```
ssh pve 'sensors 2>/dev/null || grep -H . /sys/class/hwmon/hwmon*/temp1_input'
```

To hand control back to iDRAC at any time:

```
ipmitool raw 0x30 0x30 0x01 0x01
```

The setting does not survive a reboot or an iDRAC reset, so the planned power
drain clears it automatically.

### SSH key auth from jj-laptop to `pve`, 2026-08-05

`pve` prompted for the root password on every connection. The laptop's existing
`~/.ssh/id_ed25519` key was installed:

```
ssh-copy-id -i ~/.ssh/id_ed25519.pub pve
```

On Proxmox, `/root/.ssh/authorized_keys` is a symlink to
`/etc/pve/priv/authorized_keys` on the pmxcfs filesystem. The append worked
through the symlink. The file now holds two keys: Proxmox's own `root@pve` RSA
key and the laptop's ed25519 key.

The `Host pve` block in `~/.ssh/config` on jj-laptop gained:

```
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Verified with `ssh -o BatchMode=yes pve`, which disables password fallback.

`pve-prod` already accepted the same key, so it needed no change.

Note: the key has no passphrase, and no ssh-agent runs on jj-laptop. Anyone
with read access to `~/.ssh/id_ed25519` gets root on `pve`.

### Useful commands on this host

```
ipmitool sdr type fan             # fan RPM
ipmitool sdr type temperature     # inlet, exhaust, per-CPU
ipmitool sel list                 # System Event Log
ipmitool mc reset cold            # reset iDRAC, ~2 min, does not reboot the host
```

Manual fan control, if the automatic curve stays broken:

```
ipmitool raw 0x30 0x30 0x01 0x00        # take manual control
ipmitool raw 0x30 0x30 0x02 0xff 0x14   # set all fans to 20%
ipmitool raw 0x30 0x30 0x01 0x01        # hand back to automatic
```

Manual control does not survive a reboot or an iDRAC reset. It also removes the
machine's own thermal protection, so use it only with the caveat below.

**Caveat.** Manual control silences the symptom and keeps the broken sensors
broken. With `0Eh` and `0Fh` dead, iDRAC cannot raise the fans if a CPU gets
hot. Fix the sensors first. Fall back to manual control only if the iDRAC reset
does not restore them.

---

## pve-prod: GitHub SSH key and host rename (2026-08-07)

### GitHub deploy access

`pve-prod` had no SSH keypair, only `authorized_keys`. Private clones from
GitHub failed with `Permission denied (publickey)`.

Generated on the host:

```
ssh-keygen -t ed25519 -N "" -C "jj@app-prod" -f ~/.ssh/id_ed25519
```

The public key was added to the `ByteSizedPi` GitHub account by hand as an
Authentication key. Verified with `ssh -T git@github.com` on the host, which
returns `Hi ByteSizedPi!`.

The key has **no passphrase**, so unattended `git pull` works. Anyone with read
access to `/home/jj/.ssh/id_ed25519` on `pve-prod` can read every private repo
on that account.

The key comment still reads `jj@app-prod` because it was generated before the
rename below. Cosmetic only.

### Host rename: app-prod to pve-prod

The host answered as `app-prod` while `~/.ssh/config` on jj-laptop, the docs,
and most comments called it `pve-prod`. Three names for one machine. Converged
on `pve-prod`.

Changed on the host:

```
sudo hostnamectl set-hostname pve-prod
sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1 pve-prod pve-prod/" /etc/hosts
sudo tailscale set --hostname=pve-prod
```

`/etc/hosts` was backed up to `/etc/hosts.bak-2026-08-07` first.

The Tailscale rename changes the MagicDNS name from `app-prod.tail2d486a.ts.net`
to `pve-prod.tail2d486a.ts.net`. On jj-laptop the `app-prod-ts` block in
`~/.ssh/config` became `pve-prod-ts` with the new HostName. The old name was
removed from `known_hosts` with `ssh-keygen -R`, and the new one was added after
confirming both paths present the same ED25519 fingerprint
`SHA256:02sPbL/9TOJYlLsOC6GVpliSQmvy1wjeQn+fAxnI6yc`.

Also renamed in this repo: the Komodo Server resource name in
`komodo/resources/servers.toml` and 18 `server =` lines in
`komodo/resources/stacks.toml`, the Homepage `server:` keys in
`stacks/platform/homepage/config/`, and every prose reference. 70 occurrences
across 17 files.

⚠️ **The Komodo Server resource must be renamed in the Komodo UI before this
repo change is pushed.** The sync matches resources by name. A push with a new
name creates a *new* Server resource, and the Periphery public key is not part
of `ServerConfig`, so the new resource would have no key and every stack would
bind to an unreachable server.

**Still outstanding.** The Cloudflare API token is still labelled
`traefik-acme-dns01-app-prod` in the Cloudflare dashboard. The label is
cosmetic and `BOOTSTRAP.md` now says `pve-prod`. Rename it in Cloudflare to
remove the drift.

---

## `pve`: six 1.2 TB SAS drives added as a RAID6 array (2026-08-14)

### What the controller looks like

`pve` has one PERC H710P Mini, firmware 21.3.5-0002, 1024 MB cache. The
battery is healthy: `Battery State: Optimal`, 99% charge, `isSOHGood: Yes`.
Write-back caching is therefore safe on this controller.

`Enable JBOD: No`. The H710P has no passthrough mode, so ZFS on bare disks is
not available without a crossflash or a separate HBA. All six PCIe slots read
`Current Usage: Available`, so an HBA can be added later.

### The backplane is ONE enclosure, not two

```
Number of enclosures on adapter 0 -- 1
Enclosure 0: Device ID 32, Number of Slots 24, type SES, Status Normal
```

The front bays look like two groups, but they are one backplane behind one
expander. **Slot position does not affect which drives can join an array.**

Occupied slots after this change:

| Slots | Drives | Use |
|---|---|---|
| 0, 1 | 2 x Seagate ST1800MM0129, 1.8 TB, 10.5k | VD 0, RAID1, 1.636 TB, the OS mirror |
| 8 to 13 | 6 x Toshiba AL14SEB120NY, 1.2 TB, 10k | VD 1, RAID6, 4.364 TB |

### The drives are DIF formatted and the PERC accepts them anyway

`smartctl` reports this on all six Toshiba drives and on neither Seagate:

```
Formatted with type 2 protection
8 bytes of protection information per logical block
```

The drives carry T10 protection information, so each sector is physically 520
bytes. The PERC reports `PI Eligibility: No` and still marks every drive
`Unconfigured(good), Spun Up`. The controller ignores the protection bytes
rather than refusing the drive. **No `sg_format` reformat was needed.**

Check this first on any future used SAS drive. A controller that refuses DIF
drives needs `sg_format --format --size=512 --fmtpinfo=0` per drive, which
takes 2 to 4 hours each and needs an HBA, because the PERC does not expose
unconfigured drives as `/dev/sg*`.

### One foreign config was cleared

Slot 11 arrived carrying the previous owner's metadata, a single-drive RAID0:

```
There are 1 foreign configuration(s) on controller 0.
Foreign configuration 0: DISK GROUP 0, Virtual Drive 0 (Target Id: 1)
Physical Disk 0: Slot 11, Device Id 11, TOSHIBA ... 87A0A0VLFL0E
```

Cleared with `megacli -CfgForeign -Clear -a0`. All six then read
`Foreign State: None`.

### Why RAID6 and not RAID5

All six drives are one cohort:

```
Manufactured in week 32 of year 2017
Accumulated power on time: 33341 hours   (33342 on slot 11)
Accumulated start-stop cycles: 97 to 98
Elements in grown defect list: 0
```

They were built in the same week and ran the same 33,341 hours in the same
array, agreeing to within 21 minutes. Zero grown defects is good, but 33,341
hours is about 76% of the 44,000-hour rated life of a 10k SAS drive. When one
wears out, the other five are at the same point in their life, and a RAID5
rebuild reads all five survivors.

`pve` also shuts down nightly, so a rebuild that does not finish in one day
resumes across a power cycle and stretches the exposure window into days.

RAID6 costs 1.2 TB against RAID5 and tolerates any two drives failing. The
media library was 300 GB at the time of this change, so 4.364 TB is 16 times
the space actually in use. The capacity loss is theoretical and the risk is
not.

### The array as built

```
megacli -CfgLdAdd -r6[32:8,32:9,32:10,32:11,32:12,32:13] \
        WB RA Direct NoCachedBadBBU -strpsz256 -a0
```

| Setting | Value | Reason |
|---|---|---|
| RAID level | 6 | See above |
| Size | 4.364 TB, `/dev/sdb` | 4 data drives of 1.09 TiB |
| Strip size | 256 KB | Media is large and sequential. VD 0 uses 64 KB. |
| Write policy | WriteBack | The BBU is Optimal, so this is safe |
| Read policy | ReadAhead | Sequential reads dominate |
| Bad BBU | NoCachedBadBBU | Falls back to write-through if the battery fails |
| Disk cache | Disk's Default (off) | The BBU protects controller cache, not disk cache |

Background initialization started automatically at a 30% rate. The array is
usable while it runs. It resumes after a reboot.

### Proxmox storage

```
pvcreate /dev/sdb
vgcreate tank /dev/sdb
lvcreate --type thin-pool -l 100%FREE -n tankdata tank
lvchange -Zn tank/tankdata
pvesm add lvmthin tank --vgname tank --thinpool tankdata --content images,rootdir
```

Storage id `tank`, 4.36 TiB, LVM-thin, chunk size 4.00 MiB.

**Zeroing is disabled (`-Zn`), which is a deliberate change from the Proxmox
default.** With 4 MiB chunks, zeroing writes 4 MiB of zeros before the first
write to every chunk, which roughly doubles write amplification while the
library grows. The pool serves one VM on a single-user host, so the stale-data
exposure that zeroing prevents does not apply here. Re-enable it with
`lvchange -Zy tank/tankdata` if the pool ever serves more than VM 110.

The pool is thin, so any virtual disk carved from it must be attached with
`discard=on` AND the guest must run `fstrim.timer`. Both halves are needed or
the volume grows forever and deleting media never returns pool space. Same
lesson as `vm-110-disk-1` on `local-lvm`.

### Change log: packages installed on `pve`, 2026-08-14

```
apt-get install -y sg3-utils
curl -sLO https://hwraid.le-vert.net/debian/pool-trixie/megacli/megacli_8.07.14-4+Debian.13.trixie_amd64.deb
apt-get install -y ./megacli_8.07.14-4+Debian.13.trixie_amd64.deb
```

`megacli` is the only way to read the PERC's own view of the drives from the
OS. Proxmox ships no MegaRAID tool, and the `megaraid_sas` driver hides the
SES enclosure, so `/sys/class/enclosure` is empty and `lsblk` shows only the
virtual drives. `sg3-utils` provides `sg_format` for the DIF case above, which
was not needed this time.

To remove: `apt purge megacli sg3-utils`.

### Useful commands

```
megacli -AdpAllInfo -a0                    # controller, cache, RAID levels
megacli -AdpBbuCmd -GetBbuStatus -a0       # battery health
megacli -EncInfo -a0                       # enclosures and slot count
megacli -PDList -a0                        # every physical drive and its state
megacli -LDInfo -Lall -a0                  # virtual drives
megacli -CfgForeign -Scan -a0              # previous owner's metadata
megacli -LDBI -ShowProg -Lall -a0          # background init progress
smartctl -x /dev/bus/0 -d megaraid,N       # SMART for physical drive N
```

`N` is the Device Id from `-PDList`, not the slot number. `smartctl --scan`
lists the valid ones.

### Final layout on VM 110 after the migration

| Slot | Volume | Size | Guest | Filesystem |
|---|---|---|---|---|
| `scsi0` | `local-lvm:vm-110-disk-0` | 64 G | `/` | OS, stays on the 1.6 TB mirror |
| `scsi2` | `tank:vm-110-disk-1` | 600 G | `/mnt/safe` | ext4, `-i 262144`, 2,457,600 inodes |
| `scsi3` | `tank:vm-110-disk-2` | 3000 G | `/mnt/data` | ext4, `-T largefile`, 3,072,000 inodes |
| `unused0` | `local-lvm:vm-110-disk-1` | 1 T | — | pre-migration original, fallback |
| `unused1` | `tank:vm-110-disk-0` | 3 T | — | the 201M-inode filesystem, fallback |

`CONFIG_ROOT` stays on the 64 G root disk. SQLite databases belong on local
storage, and the OS mirror is already redundant.

Both fallbacks were kept deliberately. Delete them only after the new
filesystem has run normally for a day:

```
qm disk unlink 110 --idlist unused1        # 258 GB back to tank
qm disk unlink 110 --idlist unused0        # 300 GB back to local-lvm
```

Verification that gated the swap, all three matching the pre-copy baseline
exactly: 1,012 files, 310 hardlinked files, 276,853,830,138 bytes, and each
hardlink pair sharing one inode across `media/` and `torrents/`.

### Trap 1: `qm disk move` silently drops discard passthrough

After `qm disk move 110 scsi1 tank`, the guest reported `fstrim` success while
the thin volume stayed 100% allocated. 746 GB was stranded.

`qm config 110` said `discard=on` and the thin pool said `Discards: passdown`,
so both looked correct. The live QEMU blockdev was the problem:

```
drive-scsi1: {"driver": "zeroinit", "file": {"driver": "raw", "file":
             {"driver": "host_device", "filename": "/dev/tank/vm-110-disk-0"}}}
```

Drive-mirror rebuilt the blockdev, left its `zeroinit` filter in place, and
dropped `"discard": "unmap"`, which the boot-time blockdev had at all three
levels. A freshly hot-plugged disk (`scsi2`) had the correct clean chain, which
is how the difference was isolated.

**A `reboot` inside the guest does not fix it.** The guest OS restarts while the
same QEMU process keeps the same blockdev. Use `qm reboot 110` on `pve`, which
does a shutdown and start and applies pending changes. After the restart the
`zeroinit` filter was gone and one `fstrim` returned 746.5 GB.

Check after any disk move:

```
echo "info block" | qm monitor <vmid> | grep -A4 drive-scsiN   # want no zeroinit
```

### Trap 2: `resize2fs` scales the inode table, and it is very expensive

Growing `/mnt/data` from 1 TB to 3 TB with `resize2fs` took the inode count
from 67 million to **201,326,592**, to hold **1,012 files**. At 256 bytes per
inode that is 51.5 GB of disk reserved for inode tables. Block accounting
confirmed it: 322 GB of blocks in use against 259 GB of real data.

The default `mke2fs` inode ratio is one inode per 16 KB, which suits a general
filesystem and is absurd for media. `resize2fs` keeps that ratio when it grows.

The rebuilt filesystem uses `-T largefile` (one inode per 1 MB):

```
mkfs.ext4 -m 0 -T largefile -E lazy_itable_init=0,lazy_journal_init=0 -L data /dev/sdd
```

3,072,000 inodes instead of 201,326,592, a 786 MB table instead of 51.5 GB, and
still 3,000 times more inodes than the library uses.

`/mnt/safe` holds photos rather than video, so it was built with `-i 262144`
(one inode per 256 KB): 2,457,600 inodes for a 600 GB volume, and 9 GB of
usable space recovered against the default ratio.

### Trap 3: rebooting during `ext4lazyinit` corrupts the new block groups

The `qm reboot` above landed while `ext4lazyinit` was still initialising the
block groups that `resize2fs` had just added:

```
EXT4-fs error (device sdb): ext4_validate_block_bitmap:423: comm ext4lazyinit:
    bg 20480: bad block bitmap checksum
    bg 24575: bad block bitmap checksum
Filesystem state: clean with errors      FS Error count: 2
```

Both groups were `[INODE_UNINIT, ITABLE_ZEROED]`, so no file data was affected,
and `Errors behavior: Continue` kept the filesystem read-write. It was still a
corrupt filesystem.

After an online grow, either let lazy init finish before rebooting, or pass
`-E lazy_itable_init=0` at `mkfs` time so there is nothing to initialise later.
The rebuild does the latter.

### Still outstanding

PSU 2 still has no C13 cable. `Power Supply AC lost` has asserted on most days
through to 14 August 2026, and `PS Redundancy` still reads `No Reading`. Six
more spinning drives raise the load on the single working supply.

**The Nokia-to-AX10 roof cable is the network bottleneck, and it is not
fixable.** Diagnosed 2026-08-14 in this order, recorded because the first two
conclusions were wrong:

1. `ethtool eno1` on jjserver showed 100 Mb/s with the link partner advertising
   only up to `100baseT/Full`. Six CRC errors in 177 million packets, so the
   link was electrically clean, which is the signature of a cable with only two
   working pairs: 100BASE-TX uses two pairs and runs perfectly, 1000BASE-T needs
   four, fails to train, and the PHY downshifts and stops advertising gigabit.
2. The Nokia G-240W-J was suspected. **Wrong.** Two different ports gave the
   same result, and the datasheet gives it 4 x 10/100/1000 Base-T ports.
3. Replacing jjserver's patch cable fixed *that* link: 100 Mb/s to
   **1000 Mb/s**, partner now advertising `1000baseT/Full`. Permanent win, and
   it is the link the restic sync to jjserver will use.
4. Throughput stayed at 11 MB/s. `tailscaled` at 75% CPU on jjserver's Intel
   i5-2500 was suspected. **Wrong.** A clean A/B with the transfer stopped gave
   11.4 MB/s direct over the LAN versus 11.0 MB/s over the tailnet. Tailscale
   costs 4%.
5. 11.4 MB/s is 91 Mbit, which is 100BASE-TX line rate. Both measurable ends
   are gigabit (`jjserver eno1` and `pve nic0`). The only unmeasured hop is the
   Nokia to the AX10 WAN port, and the Archer AX10 has a gigabit WAN port.

The cable is a single self-installed run through the roof from the main house
to the bedroom. No wall plates and no patch leads, so there is no cheap segment
to swap. If it is over the 100 m 1000BASE-T limit, no re-termination helps.

**Consequence beyond the homelab:** every device on `10.42.0.0/24` reaches the
internet through that cable, so the whole bedroom network is capped near
94 Mbit regardless of the fibre plan. The main house, wired straight into the
Nokia, is not.

Lesson for the next time throughput looks wrong: measure each hop, and do not
trust a CPU figure that is a symptom of pushing traffic rather than a cause.
