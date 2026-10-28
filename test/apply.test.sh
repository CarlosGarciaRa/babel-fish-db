#!/usr/bin/env bash
# Exercises the SQL applier against a disposable PostgreSQL container.
# Requires Docker and a psql client. Never touches a configured DATABASE_URL.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
name="bf-sql-test-$$"
password="$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
failures=0

cd "$root"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

check() {
  local label="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$label"
  else printf 'FAIL %s\n' "$label" >&2; failures=$((failures + 1)); fi
}

docker run -d --rm --name "$name" -e POSTGRES_PASSWORD="$password" -e POSTGRES_USER=bf \
  -e POSTGRES_DB=bf -p 127.0.0.1::5432 postgres:18 >/dev/null
port="$(docker port "$name" 5432/tcp | head -1 | sed 's/.*://')"
export DATABASE_URL="postgresql://bf:${password}@127.0.0.1:${port}/bf"
for _ in $(seq 1 60); do psql "$DATABASE_URL" -X -q -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done
psql "$DATABASE_URL" -X -q -c 'SELECT 1' >/dev/null

q() { psql "$DATABASE_URL" -X -tA -c "$1"; }

check "first application applies every script" \
  test "$(bin/apply.sh)" = "Applied: 0001_jobs.sql, 0002_audio_receipts.sql, 0003_accounts_and_ownership.sql"
check "repeating is a no-op" test "$(bin/apply.sh)" = "SQL schema is current"
check "verify reports current" test "$(bin/verify.sh)" = "SQL schema is current"

# An applied file may never change, even when nothing is pending.
cp sql/0002_audio_receipts.sql /tmp/bf-0002.$$
printf -- '-- edited\n' >> sql/0002_audio_receipts.sql
check "a modified applied file is rejected" bash -c '! bin/apply.sh >/dev/null 2>&1'
cp /tmp/bf-0002.$$ sql/0002_audio_receipts.sql && rm -f /tmp/bf-0002.$$
check "restoring the file unblocks the applier" test "$(bin/apply.sh)" = "SQL schema is current"

# A failing batch rolls back both the DDL and the ledger.
printf 'CREATE TABLE public.probe (id int);\nSELECT * FROM public.missing_table;\n' > sql/0004_probe.sql
check "a broken pending script fails" bash -c '! bin/apply.sh >/dev/null 2>&1'
rm -f sql/0004_probe.sql
check "no partial DDL survives" test "$(q "SELECT coalesce(to_regclass('public.probe')::text,'null')")" = "null"
check "the ledger keeps only applied files" test "$(q 'SELECT count(*) FROM public.schema_changes')" = "3"

# A pending script older than the last applied one is refused.
tmpdir="$(mktemp -d)"
cp sql/0001_jobs.sql sql/0003_accounts_and_ownership.sql "$tmpdir/"
q "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null
bin/apply.sh "$tmpdir" >/dev/null
cp sql/0002_audio_receipts.sql "$tmpdir/"
check "out-of-order scripts are refused" bash -c '! bin/apply.sh "$1" >/dev/null 2>&1' _ "$tmpdir"
rm -rf "$tmpdir"

# Concurrent runs never apply the same script twice.
q "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null
bin/apply.sh >/dev/null & p1=$!
bin/apply.sh >/dev/null & p2=$!
wait $p1; first=$?
wait $p2; second=$?
check "concurrent runs both succeed" test "$first" = "0" -a "$second" = "0"
check "concurrent runs apply each script once" test "$(q 'SELECT count(*) FROM public.schema_changes')" = "3"

# The real 0001 -> 0002 -> 0003 evolution preserves existing rows.
q "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null
tmpdir="$(mktemp -d)"
cp sql/0001_jobs.sql "$tmpdir/"; bin/apply.sh "$tmpdir" >/dev/null
q "INSERT INTO public.jobs (id,idempotency_key,fingerprint,audio_sha256,status,source_language,target_language,created_at,updated_at)
   VALUES (gen_random_uuid(),gen_random_uuid(),repeat('a',64),repeat('a',64),'awaiting_audio','es','es',clock_timestamp(),clock_timestamp());" >/dev/null
cp sql/0002_audio_receipts.sql "$tmpdir/"; bin/apply.sh "$tmpdir" >/dev/null
check "0002 preserves the existing row" test "$(q 'SELECT count(*) FROM public.jobs')" = "1"
check "0002 leaves receipt columns empty" test "$(q 'SELECT count(*) FROM public.jobs WHERE audio_started_at IS NULL AND audio_file_id IS NULL')" = "1"
rm -rf "$tmpdir"

# 0003 refuses to invent an owner for pre-existing jobs.
check "0003 fails loudly on ownerless rows" bash -c '! bin/apply.sh >/dev/null 2>&1'

printf '\n%s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
