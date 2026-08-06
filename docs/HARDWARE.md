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
