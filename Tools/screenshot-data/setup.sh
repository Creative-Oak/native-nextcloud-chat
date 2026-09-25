#!/usr/bin/env bash
# Starts the throwaway screenshot server, installs Talk, and seeds it.
#
#   ./setup.sh            start (or reuse) the server and seed it
#   ./setup.sh --reset    throw everything away first, then start and seed
#
# Extra arguments after `--` go to seed.py, e.g. `./setup.sh -- --no-backdate`.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--reset" ]]; then
    docker compose down -v
    shift
fi
[[ "${1:-}" == "--" ]] && shift

docker compose up -d

occ() { docker compose exec -T -u www-data app php occ "$@"; }

echo "Waiting for Nextcloud to finish installing…"
for _ in $(seq 1 120); do
    if occ status --output=json 2>/dev/null | grep -q '"installed":true'; then break; fi
    sleep 2
done
occ status --output=json | grep -q '"installed":true' || { echo "Nextcloud did not come up." >&2; exit 1; }

if ! occ app:list --output=json | grep -q '"spreed"'; then
    occ app:install spreed
fi
occ app:enable spreed >/dev/null

# The seeder makes a lot of requests in a few seconds; nothing here is exposed to anyone.
occ config:system:set ratelimit.protection.enabled --value=false --type=boolean >/dev/null
occ config:system:set auth.bruteforce.protection.enabled --value=false --type=boolean >/dev/null
# Keep Talk's own conversations ("Talk updates", sample conversations) out of the sidebar.
occ config:app:set spreed changelog --value=no >/dev/null
occ config:app:set spreed create_samples --value=no >/dev/null
# Nothing in the browser between you and approving kvidr at sign-in.
occ app:disable firstrunwizard >/dev/null 2>&1 || true

python3 seed.py "$@"

# The scenario has a call in progress; Talk ends it unless someone keeps checking in.
python3 seed.py --keep-call
