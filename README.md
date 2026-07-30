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
│   └── resources/           #   desired state, read by the Resource Sync
│       ├── servers.toml     #     sync order matters: servers before stacks
│       ├── variables.toml
│       ├── stacks.toml
│       └── procedures.toml
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
cd stacks/prowlarr
docker compose --env-file ../common.env --env-file prowlarr.env up
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

The Resource Sync webhook creates the Stack; its own webhook deploys it.

## Two webhooks, two jobs

| Webhook | Fires on | Does |
|---|---|---|
| Resource Sync | any push to `main` | diffs `komodo/resources/*.toml`, creates/updates/deletes resources |
| Stack | any push to `main` | re-clones and redeploys that stack |

Both only trigger for the branch configured on the resource. A branch mismatch
fails silently rather than loudly — this repo uses `main` throughout, matching
Komodo's default.

Image updates are separate from git entirely: `auto_update = true` polls the
registry for newer digests and redeploys on its own schedule.
