#!/bin/sh
# Refuse to deploy while a Komodo Variable is unresolved.
#
# ── Why this is a script and not an inline pre_deploy command ────────────
#
# Readability and testability, and nothing more dramatic than that. The
# inline version is a single unreadable line of escaped shell inside a TOML
# string, and it cannot be run on its own to check that it works. This can:
#
#   sh check-secrets.sh some.env    # exit 1 and lists the offending keys
#
# ⚠️ A CORRECTION, recorded because the wrong version was committed first.
#
# The move was originally justified by a claim that the inline guard broke
# deploys: Komodo's variable syntax is the double square bracket, the guard
# must search for that sequence, and Komodo interpolates pre_deploy commands,
# so the guard supposedly mangled itself.
#
# That was wrong. The inline guard was added in 147ac0d and the stack
# deployed fine at c77fe04, which came after it. The real cause of the
# apparent stall was the side-car rule — commits touching only blueprints/ or
# only this script do not change `file_paths`, so Komodo correctly does not
# redeploy. Nothing was broken; the deploys that "went missing" were deploys
# that should never have happened.
#
# Building the bracket pair from octal escapes below is therefore belt and
# braces, not a fix. It costs nothing and removes the question.
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
