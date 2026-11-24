# Notifications (ntfy)

Set up on 2026-11-09. Every server event goes to ntfy at
`ntfy.admin.jjventer.co.za`, the tailnet and LAN name. The phone receives
notifications only while Tailscale runs or while it is at home. See
`stacks/platform/ntfy/ntfy.env`.

## Topics

Subscribe to each topic separately in the ntfy Android app. The app sets the
sound per topic, so the topic decides how loud an event is.

| Topic | Phone setting | What goes there |
|---|---|---|
| `srv-urgent` | Sound on. Priority 5 overrides Do Not Disturb | Something is broken or needs JJ now |
| `srv-media` | Normal notification | Something new to watch, a new request, "leaving soon" |
| `srv-log` | **Muted** (notifications off) | History only. Read it when something looks wrong |

Mute `srv-log` in the app. Some publishers (Maintainerr, Seerr's webhook)
cannot set a priority and send priority 3, which would make a sound.

The old topic `alerts` is no longer used.

## Phone

JJ's Android phone uses the ntfy app with the user `phone`, which has
read-only access to `srv-*` and nothing else (set up 2026-11-23). If the
phone is lost, remove that user: `docker exec ntfy ntfy user del phone`.

Tailscale is on only when JJ wants it, so alerts arrive when the phone next
joins the tailnet. ntfy keeps messages for 30 days (`NTFY_CACHE_DURATION`),
so nothing is lost, only late. Instant delivery is on for each topic, and
the app's battery setting is Unrestricted.

To test the phone, publish with the `manual-test` token, kept in
`~/arrtest/ntfy/manual-test` on pve-prod (mode 600):

    T=$(cat ~/arrtest/ntfy/manual-test)
    docker exec ntfy wget -qO- --header "Authorization: Bearer $T" \
      --header "Title: Test" --header "Priority: 5" --post-data "hello" \
      http://localhost:80/srv-urgent

## Publishers

All publishers use the ntfy user `alerts` (write-only on `alerts` and
`srv-*`). Each publisher has its own token, labelled with its name, so one
token can be revoked alone:

    docker exec ntfy ntfy token list alerts
    docker exec ntfy ntfy token remove alerts tk_...

Containers on the `ingress` network post to `http://ntfy`. Others use the
HTTPS name.

| Publisher | Where it is set | srv-urgent | srv-media | srv-log |
|---|---|---|---|---|
| Sonarr | Settings > Connect, 3 entries "ntfy: ..." | Health issue, manual interaction needed | Import complete (once per download) | Grab, upgrade, series add/delete, file delete, health restored, app update |
| Radarr | Settings > Connect, 3 entries "ntfy: ..." | Health issue, manual interaction needed | Movie imported | Grab, upgrade, movie add/delete, file delete, health restored, app update |
| Seerr | Settings > Notifications: ntfy agent (urgent) and webhook agent (media) | Request waiting for approval, request failed, issue reported or reopened | Request approved or auto-approved | |
| Jellyfin | Webhook plugin, 3 generic destinations "ntfy: ..." | User locked out | | Failed login, pending restart, plugin changes. Playback start/stop of family users |
| Maintainerr | Settings > Notifications, 3 entries "ntfy: ..." on both rule groups | Rule or collection handling failed | Added to "Leaving soon", about to be deleted (3 days before) | Deleted, removed from collection, update available |
| Netdata | `${CONFIG_ROOT}/netdata/config/health_alarm_notify.conf` (custom sender) | CRITICAL (priority 5), and its clear | | WARNING and every other change |
| Tdarr | Flow `flowCompanion720`, PLACE step (`stacks/media/tdarr/flows/build_flow.py`) | | | Companion written |
| Tdarr errors | Side-car `tdarr-error-watch` (`stacks/media/tdarr/watch/errors.py`), polls every 15 min, token = the flow's | New file in the error table (priority 3) | | |
| Gatus | `stacks/platform/gatus/config/config.yaml`, token in `${CONFIG_ROOT}/gatus/ntfy.env` (label `gatus`) | A check failed 3 times in a row, and its recovery (priority 4) | | |
| Proxmox `pve` | `/etc/pve/notifications.cfg` on pve: webhook targets `ntfy-urgent`, `ntfy-log`, matchers `to-ntfy-urgent`, `to-ntfy-log` (token label `pve`, copy in `~/arrtest/ntfy/pve` on pve-prod) | Severity error: failed backup, fencing, root mail from smartd and ZED (priority 5) | | info, notice, warning: package updates, finished jobs (priority 2) |
| restic | `backup/restic-backup-failed.service`, `/etc/restic/ntfy.env` | Backup failed (priority 5) | | |
| Komodo | Alerters in the Komodo UI (see below) | Server unreachable, disk/CPU/memory, stack or container down, failed procedure | | Image updates, auto-updates |

Not covered: the iDRAC hardware event log (SEL) on the R720xd. Proxmox does
not read it.

### Proxmox (`pve`)

Set up 2026-11-24 with `pvesh`. The webhook targets send the token as the
Proxmox secret `token`, so it is not readable in the config file. The built-in
`default-matcher` (everything to `mail-to-root`) is unchanged. Test:

    pvesh create /cluster/notifications/targets/ntfy-urgent/test

### Jellyfin playback filter

The playback destination uses the Webhook plugin's user filter, which is an
INCLUDE list. Today it holds only `family-test`. Add each new family user
there, or their playback is not logged.

### Netdata

The built-in ntfy sender ignores the `url|critical` recipient filter. It
posted to `.../srv-urgent|critical` and got HTTP 404. The custom sender in
`health_alarm_notify.conf` chooses the topic by alarm status instead. Test:

    docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test

### restic

Until 2026-11-09 `/etc/restic/ntfy.env` did not exist on pve-prod. systemd
cannot start a unit whose `EnvironmentFile` is missing, so a failed backup
would have sent nothing.

### Komodo

Komodo alerters exist only in the UI (Alerters > New, endpoint type Ntfy).
Komodo's ntfy endpoint cannot send an auth header, so the token is in the URL
as ntfy's `?auth=` parameter (base64url of `Bearer tk_...`, token label
`komodo`). The two URLs are in `~/arrtest/ntfy/komodo-urls.txt` on pve-prod
(mode 600).

## Test every route

The last messages per topic are in ntfy's cache:

    sqlite3 /mnt/docker-data/appdata/ntfy/cache.db \
      "select datetime(time,'unixepoch','localtime'),topic,priority,title from messages order by time desc limit 20"
