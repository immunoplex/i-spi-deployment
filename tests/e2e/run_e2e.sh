#!/usr/bin/env bash
# =============================================================================
# tests/e2e/run_e2e.sh -- end-to-end test of the local stack: a real fit.
#
#   1. start local/docker-compose.yml on an EMPTY database (fresh volume), with
#      a generated .env if none exists;
#   2. wait for PostgreSQL (schema from db/), the compute API and I-SPI;
#   3. seed a tiny synthetic study (tests/e2e/seed.sql);
#   4. submit a frequentist fit for its curves to the API, as I-SPI does;
#   5. poll the job until it finishes;
#   6. check the results in the database (tests/e2e/check.sql).
#
# Usage (from the repo root):  tests/e2e/run_e2e.sh
#   KEEP_STACK=1   leave the stack running afterwards (default: docker compose down -v)
#   JOB_TIMEOUT    seconds to wait for the fit (default 1200)
#   PYTHON         python executable (default python3)
# Needs: docker with compose v2, curl, python3. Destroys the local stack's data.
# =============================================================================
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root/local"
PY=${PYTHON:-python3}
JOB_TIMEOUT=${JOB_TIMEOUT:-1200}
compose() { docker compose "$@"; }
psql_e2e() { compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U postgres -d immunoplex "$@"; }
log() { printf '[e2e %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

if [ ! -f .env ]; then
  log "no local/.env: generating one with random secrets"
  { for k in POSTGRES_PASSWORD REDIS_AUTH API_KEY DEX_CLIENT_SECRET; do
      printf '%s=%s\n' "$k" "$("$PY" -c 'import secrets; print(secrets.token_hex(24))')"; done
    printf 'WORKER_CORES=2\nWORKER_CPUS=2\nWORKER_MEMORY=6g\n'; } > .env
fi
API_KEY=$(grep -E '^API_KEY=' .env | cut -d= -f2-)

cleanup() {
  status=$?
  if [ $status -ne 0 ]; then
    log "FAILED -- recent worker and API logs:"
    compose logs --tail 80 i-spi-compute-worker i-spi-compute-api 2>&1 | tail -120 || true
  fi
  if [ "${KEEP_STACK:-0}" != "1" ]; then compose down -v >/dev/null 2>&1 || true; fi
  exit $status
}
trap cleanup EXIT

log "starting the stack on a fresh database"
compose down -v >/dev/null 2>&1 || true
compose up -d --quiet-pull

wait_for() {  # wait_for <description> <seconds> <command...>
  local what=$1 secs=$2; shift 2
  for _ in $(seq 1 "$secs"); do if "$@" >/dev/null 2>&1; then log "$what: ready"; return 0; fi; sleep 1; done
  log "$what: not ready after ${secs}s"; return 1
}
wait_for "postgres" 180 compose exec -T postgres pg_isready -U postgres -d immunoplex
wait_for "schema"   120 psql_e2e -tAc "SELECT 1 FROM madi_results.schema_version WHERE version = '0.7.1'"
wait_for "compute api" 120 curl -fsS http://localhost:8000/health
wait_for "i-spi" 180 curl -fsS -o /dev/null http://localhost:3838/

log "seeding the synthetic study"
psql_e2e -f - < "$root/tests/e2e/seed.sql"
# the job body I-SPI sends: curve ids, their multiplate groups, the engine
payload=$("$PY" -c '
import json, sys
cids, gids = sys.argv[1], sys.argv[2]
n = len(cids.split(","))
parts = (cids + "," + gids).split(",")
print(json.dumps({"curve_ids": [int(x) for x in parts[:n]],
                  "multiplate_group_ids": parts[n:],
                  "script_type": "frequentist", "params": {}, "cdan_cv_threshold": 20}))
' "$(psql_e2e -tAc "SELECT string_agg(curve_id::text, ',' ORDER BY curve_id) FROM madi_results.curve_lookup WHERE study_accession = 'E2E'")" \
  "$(psql_e2e -tAc "SELECT string_agg(multiplate_group_id::text, ',' ORDER BY curve_id) FROM madi_results.curve_lookup WHERE study_accession = 'E2E'")")

log "submitting a frequentist job"
resp=$(curl -fsS -X POST http://localhost:8000/jobs -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" -d "$payload")
job_id=$(printf '%s' "$resp" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["job_id"])')
log "job $job_id queued"

t0=$(date +%s); status=queued
while :; do
  st=$(curl -fsS "http://localhost:8000/jobs/$job_id" -H "X-API-Key: $API_KEY")
  status=$(printf '%s' "$st" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d["status"])')
  case "$status" in completed|failed|cancelled) break ;; esac
  if [ $(( $(date +%s) - t0 )) -gt "$JOB_TIMEOUT" ]; then log "job still '$status' after ${JOB_TIMEOUT}s"; exit 1; fi
  sleep 10
done
elapsed=$(( $(date +%s) - t0 ))
log "job $status after ${elapsed}s"
if [ "$status" != "completed" ]; then
  printf '%s' "$st" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print("error:", d.get("error"))'
  exit 1
fi

log "checking the results"
psql_e2e -v job_id="$job_id" -f - < "$root/tests/e2e/check.sql"
log "PASSED (fit took ${elapsed}s)"
