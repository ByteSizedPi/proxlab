#!/bin/sh
# Refuse to deploy while a Komodo Variable is unresolved.
#
# ── Why this is a script and not an inline pre_deploy command ────────────
#
# It was inline in komodo/resources/stacks.toml first, and that broke the
# deploy silently.
#
# Komodo's own variable syntax is [[NAME]]. The guard has to search for a
# literal `[[` to detect an unresolved placeholder, so the command contained
# `[[` itself — and Komodo interpolates pre_deploy commands before running
# them. The guard was therefore mangled by the very mechanism it exists to
# check, the deploy stopped happening, and nothing logged a cause: Periphery
# recorded no error and Core logged only "Successfully authenticated incoming
# webhook" with no run after it. The stack simply stayed at its previous
# commit while pushes appeared to succeed.
#
# Keeping the `[[` inside a committed script means Komodo never sees it.
#
# ── What it guards against ──────────────────────────────────────────────
#
# A missing Komodo Variable does NOT fail a deploy and does NOT produce an
# empty value. Komodo writes the placeholder through literally:
#
#     AUTHENTIK_PG_PASS=[[AUTHENTIK_PG_PASS]]
#
# That is a valid non-empty string, so compose's ${VAR:?required} never
# fires. On 2026-08-17 this brought the whole stack up HEALTHY with a signing
# key guessable from this repo, and postgres initialised its database using
# the placeholder as the superuser password. Postgres applies
# POSTGRES_PASSWORD at initdb time only, so adding the real Variable
# afterwards does not repair it — recovery was deleting the data directory.
#
# A healthy container is not evidence that secrets resolved.

set -eu

ENV_FILE="${1:-komodo.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "check-secrets: no $ENV_FILE next to the compose file; nothing to check."
    exit 0
fi

# Built from octal escapes so the two characters never appear literally in
# this file either. printf '\133' is '['.
OPEN=$(printf '\133\133')

if grep -qF "$OPEN" "$ENV_FILE"; then
    echo "================================================================"
    echo " ABORT: unresolved Komodo Variables in $ENV_FILE"
    echo ""
    grep -F "$OPEN" "$ENV_FILE" | cut -d= -f1 | sed 's/^/   missing: /'
    echo ""
    echo " Create each one in Komodo (Settings > Variables) with Secret"
    echo " enabled, then deploy again."
    echo ""
    echo " Deploying now would NOT fail. It would come up healthy using the"
    echo " placeholder text as the real value, and for postgres that is"
    echo " unrecoverable without deleting the database."
    echo "================================================================"
    exit 1
fi

echo "check-secrets: all Komodo Variables in $ENV_FILE resolved."
