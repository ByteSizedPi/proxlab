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

⚠️ If the deploy fails on `../common.env`, Komodo rejected path traversal above
`run_directory`. Switch to the repo-root form documented in `stacks.toml`:

```toml
run_directory = "stacks"
file_paths = ["prowlarr/compose.yaml"]
additional_env_files = ["common.env", "prowlarr/prowlarr.env"]
```

Test this on one stack before writing twenty more entries — it changes all of
them.

## 12. Deploy trigger: poll now, webhooks later

**Stay on `KOMODO_RESOURCE_POLL_INTERVAL` while `app-prod` is shut down
nightly.** A webhook fires once; if the box is off, GitHub retries briefly,
gives up, and that push is missed permanently. Polling reconciles to current
`main` on next boot.

Webhooks also need `app-prod` reachable *inbound* from GitHub, which needs the
VPS ingress. Revisit both together.

When that day comes: Komodo generates the URL per resource; GitHub → Settings →
Webhooks → payload URL, `application/json`, secret = `KOMODO_WEBHOOK_SECRET`,
push events only. Webhooks fire only for the branch configured on the resource,
and a mismatch fails silently.

## 13. Adopt Core into Komodo

Only once everything above is proven. Uncomment the `komodo-core` block in
`komodo/resources/stacks.toml` (`run_directory = "/home/jj/proxlab/komodo"`),
push, let the sync create it.

Deploying it restarts Core, so the UI disconnects and the log may show a
failure that actually succeeded. Keep `webhook_enabled = false` and
`auto_update = false` — never auto-update the thing performing updates.

## 14. Harden

```
KOMODO_UI_WRITE_DISABLED=true
```

Git becomes the only path to change config. Do this **last** — while it's on
you cannot fix a broken sync from the UI.

---

## Steady state

```
edit a compose file → push → poll picks it up → redeploy
add a stack         → push → sync creates it  → deploy
new image upstream  → auto_update polls registry (no git involved)
rotate a secret     → UI → Variables → redeploy the stack
```
