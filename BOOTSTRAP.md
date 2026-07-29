# Bootstrap runbook

One-time setup, in order. Steps 1–2 are local; 3 onward are on `app-prod`.

Each step says what breaks if you skip it. Don't reorder — several steps exist
only to make a later one safe.

---

## 1. Push the repo (local)

```sh
cd /home/jj/server
git remote add origin git@github.com:GITHUB_USER/server.git
git push -u origin main
```

Then replace the `GITHUB_USER/server` placeholder in
`komodo/resources/stacks.toml` with the real path, commit, push again.

## 2. Decide public or private

Public is fine — this repo contains no secrets by construction. If you make it
private, you must add a git provider token in step 8 or Komodo cannot clone.

---

## 3. Back up Mongo before touching anything

```sh
ssh app-prod
docker exec -t $(docker ps -qf name=komodo-mongo) \
  mongodump --archive --gzip \
  -u "$KOMODO_DATABASE_USERNAME" -p "$KOMODO_DATABASE_PASSWORD" \
  > ~/komodo-backup-$(date +%F).archive.gz
ls -lh ~/komodo-backup-*.archive.gz
```

Everything after this modifies a running Komodo. This is your undo.

## 4. Record what's currently running

```sh
cd ~/komodo
cp compose.env ~/compose.env.bak
docker compose -f mongo.compose.yaml ps
docker volume ls | grep komodo
```

Note the volume names. They'll be `komodo_mongo-data`, `komodo_mongo-config`,
`komodo_keys` — prefixed with the **project name**, which Compose derives from
the directory name (`komodo`).

This matters for step 6: the new location `/home/jj/server/komodo` is *also*
named `komodo`, so the project name is unchanged and the existing volumes are
reused. Put the repo anywhere else and Compose invents a new project, creates
empty volumes, and you get a blank Komodo with your data orphaned.

## 5. Install Periphery as a systemd unit

Currently Periphery is a container inside the Core stack. It has to move out
before Komodo can manage Core — see `periphery/README.md` for why.

```sh
curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py | python3
sudo systemctl enable --now periphery
systemctl status periphery
curl -s http://localhost:8120/health || echo "not up yet"
```

⚠️ **The container and systemd Periphery do not share key material.** The
container's Noise keys are in the `komodo_keys` volume; the systemd install
generates its own under `/etc/komodo`. After the switch, Core will show the
server as unreachable until you reconcile them — either point
`periphery.config.toml` at the same keys, or accept the new public key on the
Server in the UI. Expect one round of "unreachable" here; it is not a failure.

📋 This creates a system-level systemd unit. Log the unit file and the reason
in `~/dotfiles/SYSTEM.md`.

## 6. Move Core onto the repo's compose file

```sh
cd ~ && git clone git@github.com:GITHUB_USER/server.git
cd ~/server/komodo
cp compose.env.example compose.env
```

Now merge your real values from `~/compose.env.bak` into `compose.env`. The
database username and password **must** match the existing Mongo volume or
Core cannot authenticate. Set these too:

- `KOMODO_JWT_SECRET` — `openssl rand -hex 32`. Empty means a new secret each
  boot, which logs you out on every redeploy of this stack.
- `KOMODO_WEBHOOK_SECRET` — `openssl rand -hex 32`. Save it; step 11 needs it.
- `KOMODO_UI_WRITE_DISABLED=false` — leave false for now.

Optionally `cp core.config.toml.example core.config.toml` if you need git
tokens or file-based secrets.

Then cut over:

```sh
cd ~/komodo && docker compose -f mongo.compose.yaml down    # keeps volumes
cd ~/server/komodo && docker compose up -d
docker compose logs -f core
```

Verify the UI loads and your existing resources are still there. If yes, the
volumes carried over correctly and `~/komodo` can be deleted (keep the backup).

---

## 7. Create the Server

UI → Servers → the `app-prod` server should already exist. Confirm its address
is `http://localhost:8120` and it shows healthy. Fix the key mismatch from
step 5 here if it's still unreachable.

## 8. Add secrets — the only thing configured by hand

UI → Settings → Variables. For each secret: create it, **toggle "Secret" on**,
save. Reference it in any compose file as `[[NAME]]`.

Nothing here goes in git. That is the whole point of the split — the repo holds
structure, Komodo holds secrets, and neither is useful to an attacker alone.

If the repo is private, add the git provider token to
`komodo/core.config.toml` under `[[git_provider]]` and restart Core. Tokens
cannot be set via environment variables — that file is the only option.

## 9. Create the Resource Sync

UI → Syncs → New.

| Field | Value |
|---|---|
| Git provider | `github.com` |
| Repo | `GITHUB_USER/server` |
| Branch | `main` |
| Resource path | `komodo/resources` |

Save, then **Execute** — but read the diff first. It should propose creating
one server and one stack. If it proposes *deleting* things, stop: your existing
UI-created resources aren't declared in the TOML yet. Either add them, or set
the sync to not manage deletes until you've reconciled.

## 10. Verify the Prowlarr stack

The sync should have created it. Deploy it and check:

```sh
docker ps | grep prowlarr
cat /etc/komodo/stacks/prowlarr/komodo.env    # path may differ
```

⚠️ If the deploy fails on `../common.env`, Komodo rejected the path traversal
above `run_directory`. Switch `stacks.toml` to the repo-root form documented in
the comments there:

```toml
run_directory = "stacks"
file_paths = ["prowlarr/compose.yaml"]
additional_env_files = ["common.env", "prowlarr/prowlarr.env"]
```

Test this on Prowlarr before writing twenty more stack entries.

## 11. Wire the webhooks

For **each** of the Sync and the Prowlarr Stack, copy its webhook URL from
Komodo, then in GitHub → repo Settings → Webhooks → Add:

| Field | Value |
|---|---|
| Payload URL | the copied Komodo URL |
| Content type | `application/json` |
| Secret | `KOMODO_WEBHOOK_SECRET` from step 6 |
| Events | Just the push event |

Test: change a comment in `stacks/prowlarr/compose.yaml`, push, watch the
Updates feed. GitHub's "Recent Deliveries" tab shows the response if nothing
happens.

Webhooks only fire for the branch configured on the resource. A mismatch fails
silently — this is the single most common reason "nothing happens on push".

## 12. Adopt Core into Komodo

Only now, with Periphery on systemd and everything else proven:

Uncomment the `komodo-core` block at the bottom of
`komodo/resources/stacks.toml`, adjust `run_directory` to wherever you cloned
(`/home/jj/server/komodo`), push, let the sync create it.

Deploying it restarts Core, so the UI will disconnect and the update log may
show a failure even though it succeeded. Reconnect and confirm. Leave
`webhook_enabled = false` — you want to watch this one deploy by hand.

## 13. Harden

Once syncs are reliably driving everything:

```
KOMODO_UI_WRITE_DISABLED=true
```

Now the UI is read-only and git is genuinely the only path to change config.
Do this last: while it's on, you cannot fix a broken sync from the UI.

---

## Steady state

```
edit compose file → push to main → Stack webhook → redeploy
add a stack       → push to main → Sync webhook  → create, then deploy
new image upstream → auto_update polls registry  → redeploy (no git involved)
rotate a secret   → UI → Variables → redeploy the stack
```
