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

# Output is captured before it's searched: with pipefail, `occ … | grep -q` can fail when
# grep stops reading early and occ dies writing the rest.
installed() { local status; status=$(occ status --output=json 2>/dev/null || true); [[ "$status" == *'"installed":true'* ]]; }

echo "Waiting for Nextcloud to finish installing (a few minutes the first time)…"
for _ in $(seq 1 150); do
    installed && break
    sleep 2
done
installed || { echo "Nextcloud did not come up. \`docker compose logs app\` says why." >&2; exit 1; }

apps=$(occ app:list --output=json)
if [[ "$apps" != *'"spreed"'* ]]; then
    echo "Installing Talk…"
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
