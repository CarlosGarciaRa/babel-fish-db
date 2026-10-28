#!/usr/bin/env bash
# Reports pending scripts and verifies that already-applied files are unmodified.
# Read-only: everything runs inside a transaction that is rolled back.
set -euo pipefail

readonly LEDGER='public.schema_changes'

die() { printf '%s\n' "$*" >&2; exit 1; }

[[ -n "${DATABASE_URL:-}" ]] || die 'DATABASE_URL is required'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sql_dir="${1:-${DATABASE_SQL_DIR:-$script_dir/../sql}}"
[[ -d "$sql_dir" ]] || die "SQL directory not found: $sql_dir"
sql_dir="$(cd -- "$sql_dir" && pwd)"

shopt -s nullglob
declare -a files=()
for path in "$sql_dir"/*.sql; do
  name="${path##*/}"
  [[ $name =~ ^[0-9]{4}_[a-z0-9_]+\.sql$ ]] && files+=("$name")
done
((${#files[@]})) || die "No numbered SQL files found in $sql_dir"
mapfile -t files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)

psql_run() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT

{
  printf 'BEGIN;\n'
  printf 'CREATE TEMP TABLE _bf_expected (filename text PRIMARY KEY, sha256 text NOT NULL);\n'
  printf 'INSERT INTO _bf_expected (filename, sha256) VALUES\n'
  for i in "${!files[@]}"; do
    name="${files[$i]}"
    sum="$(sha256sum -- "$sql_dir/$name" | cut -d' ' -f1)"
    sep=','
    (( i == ${#files[@]} - 1 )) && sep=';'
    printf "    ('%s', '%s')%s\n" "$name" "$sum" "$sep"
  done
  cat <<'SQL'
DO $bf$
DECLARE
    l_invalid text;
BEGIN
    IF to_regclass('public.schema_changes') IS NULL THEN
        RETURN;
    END IF;
    SELECT string_agg(s.filename, ', ' ORDER BY s.filename) INTO l_invalid
      FROM public.schema_changes s
      LEFT JOIN _bf_expected e ON e.filename = s.filename AND e.sha256 = s.sha256
     WHERE e.filename IS NULL;
    IF l_invalid IS NOT NULL THEN
        RAISE EXCEPTION 'Applied SQL file missing or modified: %', l_invalid;
    END IF;
END
$bf$;
SELECT coalesce(string_agg(e.filename, E'\n' ORDER BY e.filename), '') AS pending
  FROM _bf_expected e
 WHERE to_regclass('public.schema_changes') IS NULL
    OR NOT EXISTS (SELECT 1 FROM public.schema_changes s WHERE s.filename = e.filename);
ROLLBACK;
SQL
} >"$tmp"

if ! output="$(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -tA -f "$tmp" 2>"$tmp.err")"; then
  printf 'Verification failed. Check the connection and the applied-file checksums.\n' >&2
  [[ "${DEBUG:-0}" == "1" ]] && cat -- "$tmp.err" >&2
  rm -f -- "$tmp.err"
  exit 1
fi
rm -f -- "$tmp.err"

if [[ -z "$output" ]]; then
  printf 'SQL schema is current\n'
else
  printf 'Pending:\n%s\n' "$output"
fi
