#!/usr/bin/env bash
# Applies the hand-written SQL scripts of this repository. No ORM, no migration generator,
# no schema synchronisation: DEC-005/006. Safe to run repeatedly; with no pending files it
# changes nothing.
#
# Usage:  DATABASE_URL=postgresql://... bin/apply.sh [sql-directory]
# Env:    DATABASE_SQL_DIR  overrides the directory when no argument is given.
#         DEBUG=1           prints the PostgreSQL error after a failure.
set -euo pipefail

readonly LEDGER='public.schema_changes'
readonly LOCK_CLASS=17832026
readonly LOCK_OBJ=1

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

declare -A checksum=() filepath=()
for name in "${files[@]}"; do
  filepath["$name"]="$sql_dir/$name"
  checksum["$name"]="$(sha256sum -- "${filepath[$name]}" | cut -d' ' -f1)"
done

tmp="$(mktemp)"; out="$(mktemp)"; err="$(mktemp)"
trap 'rm -f -- "$tmp" "$out" "$err"' EXIT

{
  printf "SET LOCAL lock_timeout = '5s';\n"
  printf "SET LOCAL statement_timeout = '30s';\n"
  printf 'DO $bf_lock$ BEGIN PERFORM pg_advisory_xact_lock(%d, %d); END $bf_lock$;\n' "$LOCK_CLASS" "$LOCK_OBJ"
  printf 'CREATE TABLE IF NOT EXISTS %s (\n' "$LEDGER"
  printf '    filename text PRIMARY KEY,\n'
  printf "    sha256 text NOT NULL CHECK (sha256 ~ '^[a-f0-9]{64}$'),\n"
  printf '    applied_at timestamptz NOT NULL DEFAULT now()\n'
  printf ');\n'
  printf 'CREATE TEMP TABLE _bf_expected (filename text PRIMARY KEY, sha256 text NOT NULL) ON COMMIT DROP;\n'
  printf 'INSERT INTO _bf_expected (filename, sha256) VALUES\n'
  for i in "${!files[@]}"; do
    name="${files[$i]}"
    sep=','
    (( i == ${#files[@]} - 1 )) && sep=';'
    printf "    ('%s', '%s')%s\n" "$name" "${checksum[$name]}" "$sep"
  done
  # Un archivo ya aplicado no se modifica ni se elimina: se detecta por checksum.
  cat <<'SQL'
DO $bf$
DECLARE
    l_invalid text;
    l_last text;
    l_first_pending text;
BEGIN
    SELECT string_agg(s.filename, ', ' ORDER BY s.filename) INTO l_invalid
      FROM public.schema_changes s
      LEFT JOIN _bf_expected e ON e.filename = s.filename AND e.sha256 = s.sha256
     WHERE e.filename IS NULL;
    IF l_invalid IS NOT NULL THEN
        RAISE EXCEPTION 'Applied SQL file missing or modified: %', l_invalid;
    END IF;

    SELECT max(s.filename) INTO l_last FROM public.schema_changes s;
    SELECT min(e.filename) INTO l_first_pending
      FROM _bf_expected e
     WHERE NOT EXISTS (SELECT 1 FROM public.schema_changes s WHERE s.filename = e.filename);
    IF l_last IS NOT NULL AND l_first_pending IS NOT NULL AND l_first_pending < l_last THEN
        RAISE EXCEPTION 'New SQL scripts must sort after all applied scripts';
    END IF;
END
$bf$;
SQL
  # La decisión de aplicar se toma dentro de la transacción y bajo el lock, para que dos
  # ejecuciones concurrentes no reintenten el mismo DDL.
  for name in "${files[@]}"; do
    printf "SELECT EXISTS (SELECT 1 FROM %s WHERE filename = '%s') AS bf_done \\\\gset\n" "$LEDGER" "$name"
    printf '\\if :bf_done\n'
    printf '\\else\n'
    printf '\\i %s\n' "'${filepath[$name]}'"
    printf "INSERT INTO %s (filename, sha256) VALUES ('%s', '%s');\n" "$LEDGER" "$name" "${checksum[$name]}"
    printf '\\echo __BF_APPLIED__ %s\n' "$name"
    printf '\\endif\n'
  done
} >"$tmp"

if ! psql "$DATABASE_URL" -X -q -1 -v ON_ERROR_STOP=1 -f "$tmp" >"$out" 2>"$err"; then
  printf 'SQL application failed; nothing was committed. Check the connection, script order and checksums.\n' >&2
  [[ "${DEBUG:-0}" == "1" ]] && cat -- "$err" >&2
  exit 1
fi

applied="$(sed -n 's/^__BF_APPLIED__ //p' "$out" | paste -sd, - | sed 's/,/, /g' || true)"
if [[ -z "$applied" ]]; then
  printf 'SQL schema is current\n'
else
  printf 'Applied: %s\n' "$applied"
fi
