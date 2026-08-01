# Bootstrap runbook

Setup for a **clean** `app-prod`, in order. Rewritten 2026-07-30 to match what
was actually done — an earlier draft described migrating a live Komodo, which
turned out not to apply.

Paths: the dev copy lives at `/home/jj/server` on the laptop; the prod clone
is `/home/jj/proxlab` on `app-prod`. Both hold `ByteSizedPi/proxlab`.

---

## 1. Push the repo (laptop)

```sh
cd /home/jj/server
git remote add origin git@github.com:ByteSizedPi/proxlab.git
git push -u origin main
```

Public repo — it contains no secrets by construction. If you make it private,
Komodo needs a git token in `komodo/core.config.toml` under `[[git_provider]]`
before it can clone; tokens cannot be supplied via environment variables.

## 2. DNS (parallel, has propagation delay)

Register the domain, then point its **nameservers** at Cloudflare from the
registrar's control panel — not by adding records at Cloudflare while the old
nameservers still answer, which fails invisibly.

```sh
dig @1.1.1.1 NS jjventer.co.za +short   # want *.ns.cloudflare.com
```

WHOIS updates immediately; the published zone lags, so a correct config can
look broken for an hour. Once it resolves, hit "Check nameservers now" on
Cloudflare, then create an **Edit zone DNS** API token scoped to this zone —
Traefik needs it for DNS-01 later, and Cloudflare shows it once.

⚠️ Don't enable DNSSEC at the registrar. If you want it, enable it from
Cloudflare and let it hand you the DS record.

---

## 3. Confirm a clean slate

```sh
ssh app-prod
docker ps -a | grep -i komodo || echo "no containers"
docker volume ls | grep -i komodo || echo "no volumes"
```

⚠️ A surviving `komodo_mongo-data` is the one thing that breaks this silently.
Mongo only reads `MONGO_INITDB_ROOT_*` when initialising an **empty** data
directory, so a new password against an old volume is ignored and Core then
fails to authenticate with nothing naming the cause.

```sh
docker volume rm komodo_mongo-data komodo_mongo-config komodo_keys
```

## 4. Storage and clone

```sh
sudo mkdir -p /mnt/docker-data/{appdata,data,komodo/backups}
sudo chown -R jj:jj /mnt/docker-data
cd ~ && git clone https://github.com/ByteSizedPi/proxlab.git proxlab
cd ~/proxlab/komodo
```

`DATA_ROOT` in `stacks/common.env` points at `/mnt/docker-data/data`. That's
fine for config, but a media library cannot live on a 63G root disk — revisit
it when the *arr stack lands.

## 5. Configure Core

```sh
cp compose.env.example compose.env
chmod 600 compose.env
ln -s compose.env .env          # see below — not optional
openssl rand -hex 16            # database password
openssl rand -hex 32            # JWT secret
openssl rand -hex 32            # webhook secret
```

Fill in every `CHANGE_ME`, set `KOMODO_HOST` to the address you actually type
in a browser, and verify:

```sh
grep -n CHANGE_ME compose.env || echo "clean"
grep -oE '^[A-Z_]+=' compose.env | sort | uniq -d   # empty = no duplicates
grep -cE '^[A-Z_]+=' compose.env                    # want 14
```

⚠️ `KOMODO_INIT_ADMIN_USERNAME` / `_PASSWORD` are only read against an **empty
database**. Typo the password and the fix is wiping volumes, not editing the
file. Omit the password entirely and it silently defaults to `changeme`.

### Why the `.env` symlink

Two separate mechanisms, both needed:

- `env_file: ./compose.env` injects variables **into** the container.
- `${KOMODO_DATABASE_USERNAME}` is substituted by Compose **before any
  container exists**, and Compose only reads the shell, `.env`, or an explicit
  `--env-file` for that.

Without the symlink, *every* Compose command needs `--env-file compose.env` —
`logs` and `ps` too, not just `up`. Forgetting it on one produces `variable is
not set` and `invalid spec: :/backups`, which reads as a config error rather
than a missing flag.

## 6. Periphery as a systemd unit

```sh
curl -sSL -o /tmp/setup-periphery.py \
  https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py
sudo python3 /tmp/setup-periphery.py
sudo systemctl enable --now periphery
systemctl status periphery --no-pager
curl -sk https://localhost:8120/health && echo " <- OK"
```

⚠️ **Download the script, don't pipe it.** `curl … | python3` makes stdin the
script, so the installer's polkit password prompt breaks the pipe. It then
reports a bogus "failed to download binary — check your version tag", which
sends you chasing the wrong problem.

Note `-k` and **https**: Periphery sets `ssl_enabled = true` and self-signs, so
plain HTTP is refused.

Periphery must stay **outside** the Core stack. Inside it, redeploying Core
restarts the agent mid-deploy and kills the deploy — see `periphery/README.md`.

Save the public key from the startup log; the UI asks for it.

📋 System-level systemd unit → log it and `/etc/komodo/periphery.config.toml`
in `~/dotfiles/SYSTEM.md`.

## 7. Start Core

```sh
cd ~/proxlab/komodo
docker compose up -d
docker compose logs -f core
```

No `-f compose.local.yaml` — that overlay adds a Periphery *container* and is
sandbox-only.

Want: `Successfully created init admin user` and `Server starting on
http://[::]:9120`.

---

## 8. Add the Server

UI → Servers → New.

| Field | Value |
|---|---|
| Name | `app-prod` — must match exactly |
| Address | `https://host.docker.internal:8120` |

⚠️ **Not `localhost`.** Core runs in a container, where `localhost` is the
container itself; Periphery is on the host. `host.docker.internal` resolves via
the `extra_hosts: host-gateway` entry on the core service in `compose.yaml` —
the two are coupled, and removing either breaks the connection.

The name must match because `stacks.toml` says `server = "app-prod"` and
`servers.toml` creates the same name. A mismatch yields two servers with the
stack bound to the wrong one.

## 9. Add secrets — the only thing configured by hand

UI → Settings → Variables. Create each, toggle **Secret** on, save. Reference
them anywhere as `[[NAME]]`.

Nothing here goes in git. The repo holds structure, Komodo holds secrets, and
neither is much use to an attacker alone.

## 10. Create the Resource Sync

UI → Syncs → New: provider `github.com`, repo `ByteSizedPi/proxlab`, branch
`main`, resource path `komodo/resources`.

⚠️ **Turn on "Include Variables".** Komodo gates Variables and User Groups
behind separate opt-in flags on the sync (`include_variables`,
`include_user_groups`), both **false** by default. Leave it off and
`variables.toml` is read, reported as parsed, and silently produces nothing —
no error anywhere.

**Execute**, and read the diff before confirming. Expect: create 1 server,
3 variables, 1 stack; delete nothing. Deletions mean UI-created resources
aren't declared in TOML yet.

## 11. Verify the Prowlarr stack

Deploy from the UI, then check what actually landed rather than trusting the
green tick:

```sh
docker inspect prowlarr --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
docker inspect prowlarr --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(PUID|TZ)'
```

Want the mount resolved to `/mnt/docker-data/appdata/prowlarr` — that proves
`CONFIG_ROOT` came out of `common.env` and was substituted, i.e. the whole env
layering resolved.

✅ Verified working 2026-07-30, including the `../common.env` traversal above
`run_directory`.

Note Periphery clones the repo *per stack*, so the run directory is nested:
`/etc/komodo/stacks/<stack>/<run_directory>`. `env_file_path` is relative to
that, not to the clone root.

`komodo.env` is absent when no compose file references a `[[VARIABLE]]` —
Komodo only writes it when there's something to interpolate. That's expected,
not a failure.

## 12. Deploy trigger: webhooks, with polling as the backstop

Webhooks are the primary trigger. Inbound reachability comes from the
Cloudflare Tunnel in `stacks/cloudflared` — no VPS needed, and it publishes
only `^/listener/.*`, so the UI stays LAN-only.

**One webhook total**, pointed at the `gitops` procedure — not one per stack.
See README.md for why. The procedure syncs resources, then batch-deploys only
the stacks whose contents changed.

Chicken-and-egg: the URL contains the procedure's ID, which doesn't exist until
the procedure has been synced into Komodo. So the first time:

1. Push `procedures.toml`.
2. Run the `resources` sync **by hand** in the UI → Syncs → `resources` →
   Execute. This creates the procedure.
3. Look up its ID (query below), add the webhook, delete any older per-stack
   webhooks.

```
https://hooks.jjventer.co.za/listener/github/procedure/<id>/main
```

Content type `application/json`, secret = `KOMODO_WEBHOOK_SECRET`, SSL
verification on, **push events only**.

The secret is not optional: the listener is on the public internet and the
HMAC signature (`X-Hub-Signature-256`) is the only thing authenticating a
caller. The Cloudflare path filter controls which URLs are reachable, not who
may call them. Komodo falls back to the global `KOMODO_WEBHOOK_SECRET` unless
a resource sets its own `webhook_secret`.

⚠️ **For Procedures and Actions the last segment is the branch, not an
execution.** Every other resource type takes an execution there — Stack
`/deploy`, Sync `/sync`, Repo `/pull`, Build `/build` — but a Procedure takes
a branch name, or `/__ANY__` for all branches. `/run` is silently interpreted
as "a branch named run" and the webhook never fires.

Probing cannot catch this: branch matching happens *after* signature
validation, so `/run` and `/main` both return `401` to an unsigned request.
Only a correctly signed delivery, or the docs, distinguish them.

⚠️ **Content type must be `application/json`.** GitHub's webhook form defaults
to `application/x-www-form-urlencoded`, which sends the payload as
`payload=%7B%22ref%22...`. Komodo fails on it with:

```
Failed to parse github request body: expected value at line 1 column 1
```

...and still returns 2xx, so **GitHub's "Recent Deliveries" shows the delivery
as successful while nothing ran.** A green tick in GitHub only proves Komodo
answered, never that it acted. Confirm against Core's logs or a new
`RunProcedure` entry in the `Update` collection:

```sh
docker logs komodo-core-1 --since 10m 2>&1 | grep -i webhook
```

A working delivery logs `Successfully authenticated incoming webhook` **and no
following WARN**.

The URL shape is `/listener/<AUTH_TYPE>/<RESOURCE_TYPE>/<NAME_OR_ID>/<EXECUTION>`.
Both a resource name and its Mongo `_id` work in that slot, but **the UI only
ever generates the ID form** — so what you copy out of Komodo won't look like
the readable name form. Get IDs with:

```sh
docker exec -e P="$KOMODO_DATABASE_PASSWORD" komodo-mongo-1 sh -c \
  'mongosh --quiet -u admin -p "$P" --authenticationDatabase admin komodo --eval "
     db.Procedure.find({},{name:1}).forEach(d=>print(d._id+\"  \"+d.name));
     db.Stack.find({},{name:1}).forEach(d=>print(d._id+\"  \"+d.name));
     db.ResourceSync.find({},{name:1}).forEach(d=>print(d._id+\"  \"+d.name))"'
```

Note the database user is `admin` (from `MONGO_INITDB_ROOT_USERNAME`), not the
`komodo` database name — easy to conflate, and the only symptom is
`Authentication failed`.

Verify a route before wiring it up, from outside the LAN:

```sh
curl -so /dev/null -w '%{http_code}\n' -X POST -d '{}' \
  https://hooks.jjventer.co.za/listener/github/procedure/<id>/main
```

Reading the codes — none of them is a plain "OK", so know which failure is
which:

| Code | Meaning |
|---|---|
| `401` | **Route is valid**, and it rejected an unsigned request. This is success. |
| `400` | Route shape is valid but the resource ID doesn't exist. Wrong/stale ID. |
| `404` | Path is wrong, *or* the Cloudflare ingress regex didn't match at all. |
| `405` | Wrong resource-type or execution segment — or you probed with `GET`. |

Know what this does *not* prove: a `401` says the signature check ran, which
happens before branch matching, so it cannot tell a good branch segment from a
bad one. See the warning above.

**Space out probes.** Core rate-limits per source IP at
`auth_rate_limit_max_attempts: 5` per `auth_rate_limit_window_seconds: 15`
(both visible in the startup config it logs). A loop firing requests
back-to-back exhausts the window and the throttled responses look like routing
failures. Sleep ~4s between probes.

Always probe with `POST`; a bare `GET` returns `405` on a perfectly good route.

Within the sync itself, `sync` applies the diff immediately while `refresh`
only marks it pending for manual confirmation. The procedure uses `RunSync`
(apply), made safe by `delete: false` and `managed: false` on the sync —
removing a stack from `stacks.toml` will *not* remove it from Komodo.

**Backstops stay on.** `app-prod` is shut down nightly and a webhook fires
exactly once: if the box is off, GitHub retries briefly, gives up, and that
push is lost permanently. Two things cover that — the `gitops` procedure's
15-minute schedule (which re-runs the same reconcile and no-ops when nothing
changed) and `KOMODO_RESOURCE_POLL_INTERVAL`. Webhooks also fire only for the
branch configured on the resource, and a mismatch fails silently.

⚠️ A push that changes `stacks/cloudflared/` redeploys the tunnel, which kills
the connection the triggering webhook arrived over. GitHub logs that delivery
as **failed** even though the procedure completed — it runs inside Core and
doesn't care that the caller went away. Confirm against Komodo's update log,
not GitHub. If such a change breaks the tunnel outright, webhooks stop
arriving entirely; recover from the LAN UI or wait for the 15-minute schedule.

## 13. Adopt Core into Komodo

Only once everything above is proven. Uncomment the `komodo-core` block in
`komodo/resources/stacks.toml` (`run_directory = "/home/jj/proxlab/komodo"`),
push, let the sync create it.

Deploying it restarts Core, so the UI disconnects and the log may show a
failure that actually succeeded. Confirm with `docker ps` on app-prod, not
from the update log.

This step is what makes Core self-updating: the block sets `auto_update` and
`poll_for_updates`, so a new `2.x` digest is picked up within one poll
interval. Safe only because Periphery is a systemd unit outside this stack —
it keeps running while Core is replaced. `webhook_enabled` stays `false`; the
`gitops` procedure deliberately doesn't reach this stack.

## 13b. Install the Periphery update timer

Core now updates itself, but Periphery doesn't — different install mechanism,
no shared version. Without this step the two drift apart on the next release
and the server goes yellow.

```sh
sudo cp periphery/systemd/komodo-periphery-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now komodo-periphery-update.timer
systemctl list-timers komodo-periphery-update.timer
```

`Persistent=true` in the timer matters: app-prod is off overnight, so a
scheduled small-hours run would never arrive. systemd instead notices the
missed run and fires it after the next boot.

Both components track the floating `2` tag. See `periphery/README.md`.

## 14. Harden

```
KOMODO_UI_WRITE_DISABLED=true
```

Git becomes the only path to change config. Do this **last** — while it's on
you cannot fix a broken sync from the UI.

---

## Steady state

```
any push           → gitops procedure → sync resources
                                      → deploy only the stacks that changed
add a stack        → same path; sync creates it, batch deploys it. No new
                     webhook, ever.
missed push (box off) → the procedure's 15-min schedule reconciles
new image upstream → auto_update polls registry (no git involved)
rotate a secret    → UI → Variables → redeploy the stack
```
