#!/usr/bin/env bash
# Load db/*.sql into a throwaway PostgreSQL and run smoke checks.
# Usage: db/tests/load_test.sh [PG_BIN]   (PG_BIN: directory with initdb, pg_ctl, psql)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
PG_BIN=${1:-$(dirname "$(command -v initdb 2>/dev/null || echo /usr/lib/postgresql/16/bin/initdb)")}
port=$((55000 + RANDOM % 900)); dir=$(mktemp -d)
trap '"$PG_BIN/pg_ctl" -D "$dir/data" -m fast stop >/dev/null 2>&1 || true; rm -rf "$dir"' EXIT
"$PG_BIN/initdb" -D "$dir/data" -U postgres --auth=trust -E UTF8 >/dev/null
"$PG_BIN/pg_ctl" -D "$dir/data" -o "-p $port" -l "$dir/pg.log" -w start >/dev/null
psql() { "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h localhost -p "$port" -U postgres -d postgres "$@"; }
# One session, exactly as db/README.md documents it (cat ... | psql).
echo "load $(cd "$here" && ls [0-9][0-9]_*.sql | tr '
' ' ')"
cat "$here"/[0-9][0-9]_*.sql | psql >/dev/null
psql -A -t -f "$here/tests/smoke.sql"
if [ -n "${DUMP_TO:-}" ]; then
  "$PG_BIN/pg_dump" -h localhost -p "$port" -U postgres --schema-only --no-owner --no-privileges postgres > "$DUMP_TO"
fi
echo "OK"
