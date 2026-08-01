# server

Declarative state for `app-prod`, deployed by [Komodo](https://komo.do).

Push to `main` → GitHub webhook → Komodo pulls, diffs, and redeploys. Nothing
is configured by hand in the UI except secrets.

## Layout

```
.
├── komodo/                  # the control plane
│   ├── compose.yaml         #   Core + Mongo (Periphery deliberately absent)
│   ├── compose.env.example  #   → copy to compose.env on app-prod (gitignored)
│   ├── core.config.toml.example
│   ├── systemd/             #   komodo-update.{service,timer} → /etc/systemd/system
│   └── resources/           #   desired state, read by the Resource Sync
│       ├── servers.toml     #     sync order matters: servers before stacks
│       ├── variables.toml
│       ├── stacks.toml
│       └── procedures.toml
├── scripts/
│   └── update-komodo.sh     # updates Core + Periphery together
├── stacks/                  # the workloads — one directory per stack
│   ├── common.env           #   shared, non-secret, committed
│   └── prowlarr/
│       ├── compose.yaml
│       └── prowlarr.env     #   per-app, non-secret, committed
└── periphery/               # the agent — systemd, outside the Core stack
```

Two top-level concepts: **the control plane**, and **what it runs**. Core's
compose file lives in `komodo/` rather than `stacks/` because everything in
`stacks/` is uniformly Komodo-managed, while Core is bootstrapped by hand
first and adopted afterwards. The directory boundary encodes that difference
so you don't have to remember it.

## Secrets

**Nothing sensitive is ever committed.** The committed `.env` files hold only
things that are harmless in a public repo — UID, timezone, mount paths.

API keys, passwords and tokens go in one of two places:

| Where | Stored in | Use when |
|---|---|---|
| UI → Settings → Variables, **Secret** toggle on | Mongo | Default. Easy to rotate, no Core restart. |
| `komodo/core.config.toml` → `[secrets]` | Disk on app-prod | Must survive database loss, or needed before Mongo is up. |

Both are referenced the same way in any compose file:

```yaml
environment:
  - API_KEY=[[PROWLARR_API_KEY]]
```

Komodo interpolates `[[NAME]]` when it writes `komodo.env` into the stack's run
directory at deploy time, and masks the value in the UI and in deploy logs.
`komodo.env` is gitignored — it is the only file that ever contains plaintext.

Git provider tokens are the one exception that *must* live in
`core.config.toml`; they cannot be set via environment variables.

⚠️ **`komodo/compose.env` on app-prod is the single point of failure.** It is
gitignored by necessity — it holds the Mongo password Core needs *before* it
can read any Komodo Variable — so it exists in exactly one place and is in no
backup. It was destroyed once, on 2026-08-01, by deleting a Komodo Repo
resource whose `path` pointed at the clone containing it. Recovery from the
running containers is documented in `BOOTSTRAP.md` step 13, but that only
works while those containers are alive. Keep a copy off-box.

## Environment layering

Each stack gets three env files, applied in this order:

```
komodo.env      ← Komodo writes it; secrets interpolated here    (lowest precedence)
common.env      ← shared defaults, committed
<stack>.env     ← per-app overrides, committed                   (highest precedence)
```

⚠️ The ordering is counterintuitive: since v1.16.12 `additional_env_files`
override `env_file_path`, so Komodo's own managed file loses conflicts. This is
only safe because the key sets are disjoint by design — secrets exist solely in
`komodo.env`, plain config solely in the committed files. **Never define the
same key in both.**

Local testing works without Komodo at all:

```sh
cd stacks/media/prowlarr
docker compose --env-file ../../common.env --env-file prowlarr.env up
```

## Healthcheck convention

**Every service in this repo defines a `healthcheck`.** No exceptions — a
container without one reports "running" while being completely broken, and
Komodo's dashboard inherits that lie.

```yaml
healthcheck:
  test: ["CMD-SHELL", "<cheap command that exits non-zero when broken>"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 30s   # longer if first boot does initialisation work
```

Rules that matter more than the numbers:

- **Probe the actual service, not the process.** `curl` its port; don't check
  that a PID exists. A wedged process is still a process.
- **Use `-f` with curl.** Without it curl exits 0 on a 404, so the check
  passes against a server that's answering nothing useful. This bit us on
  `app-prod`: `curl -sk .../health` printed OK against a 404 for weeks'
  worth of false confidence.
- **Verify the command inside the image before committing it.** These images
  are minimal and differ — Core and Periphery have `curl`, Mongo has
  `mongosh`, none have a shell beyond `sh`.
- **`start_period` is not `interval`.** Failures during `start_period` don't
  count toward `retries`, so set it to the real cold-start time or the
  container gets killed while legitimately starting.
- **Depend on health, not existence.** `depends_on: condition:
  service_healthy` is what makes a healthcheck do work at boot rather than
  just colour a dashboard.

Upstream Komodo ships no healthchecks and documents no health endpoint, so
the ones here were determined empirically and are noted as such in-file.

**Exceptions must be justified in the compose file itself.** Some images are
distroless — `cloudflare/cloudflared` has no shell, no curl, no wget — and
Docker can only run binaries the image already contains, so no probe is
possible. In that case write *no* healthcheck and explain why, next to where
it would have gone. Never write a placeholder like `CMD true`: it reports
healthy unconditionally, which is the precise false-confidence failure this
convention exists to prevent.

## Adding a stack

1. `mkdir stacks/<name>` with a `compose.yaml` and a `<name>.env`
2. Add a `[[stack]]` block to `komodo/resources/stacks.toml`
3. Commit and push to `main`

That's the whole procedure. No webhook to add, nothing to click: the `gitops`
procedure's sync stage creates the Stack and its batch stage deploys it,
because a stack that has never been deployed counts as changed.

## One webhook

There is exactly **one** GitHub webhook, and it stays at one no matter how many
services get added. It points at the `gitops` procedure
(`komodo/resources/procedures.toml`), which runs two stages in order:

| Stage | Execution | Does |
|---|---|---|
| 1 | `RunSync` | diffs `komodo/resources/*.toml`, creates/updates resources |
| 2 | `BatchDeployStackIfChanged` (`pattern = "*"`) | redeploys only stacks whose contents changed |

Stage 2 is the part that makes this scale: Komodo compares deployed contents
against latest contents per stack and skips the ones that match, so a push
touching one compose file restarts one container. A docs-only push restarts
nothing. And because stage 1 runs first, a brand-new stack is created and then
deployed in the same run — no bootstrap click, no new webhook.

A webhook per Stack resource also works and is what the UI nudges you toward.
It was rejected: it makes every new service a manual step in GitHub's settings,
scatters state that belongs in this repo across a web UI, and can't deploy a
stack that doesn't exist yet.

Webhooks only trigger for the branch configured on the resource, and a branch
mismatch fails silently rather than loudly — this repo uses `main` throughout,
matching Komodo's default.

URLs are `/listener/<AUTH_TYPE>/<RESOURCE_TYPE>/<NAME_OR_ID>/<EXECUTION>`, and
accept either a resource name or its Mongo `_id` — but the UI only generates
the ID form, so what you copy out of Komodo won't match the readable form.
Setup, verification and how to look up IDs: `BOOTSTRAP.md` step 12.

Inbound reachability is the Cloudflare Tunnel in `stacks/platform/cloudflared`,
which publishes `^/listener/.*` and nothing else.

Image updates are separate from git entirely: `auto_update = true` polls the
registry for newer digests and redeploys on its own schedule.

## What Komodo does *not* manage

Komodo itself. Core and Periphery are updated by `scripts/update-komodo.sh`,
run weekly by `komodo/systemd/komodo-update.timer` on app-prod, and updating
both in one pass is what keeps their versions from drifting.

Self-management was built and removed on 2026-08-01. Core's `compose.env`
holds the Mongo password, so it can't come from a Komodo Variable — those live
in the database that password unlocks. That forces `files_on_host`, which
reads a clone nothing refreshes, which needs a Repo resource to refresh it,
which fails on `detected dubious ownership` because Periphery runs as root
against a `jj`-owned clone. Three layers of machinery to update one container,
and a drift window a shell script closes for free.

The rule that came out of it: **the control plane doesn't deploy itself.**
Everything that isn't Komodo is fully automated; Komodo is a weekly timer.
