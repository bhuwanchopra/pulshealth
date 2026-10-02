#!/usr/bin/env bash
# Restore a PulsHealth database dump (SRV-9). Run from the host, from anywhere
# in the checkout:
#
#   server/backup/restore.sh <dump file>                   # a path on this machine
#   server/backup/restore.sh puls-20260908T031500Z.dump    # a name in the backup store
#   make restore FILE=<either of the above>
#
#   --yes        skip the confirmation prompt (for scripted drills)
#   --no-start   leave the app services stopped when the restore finishes,
#                instead of bringing the stack back up
#   --build      bring the stack back up from this checkout rather than the
#                published images (server/compose.build.yml) — the same
#                choice `scripts/bootstrap.sh --build` makes, and the same
#                PULS_BOOTSTRAP_BUILD=1 environment variable turns it on
#
# THIS DESTROYS THE CURRENT CONTENTS OF THE DATABASE. Everything in the `public`
# schema, and the web viewer's `auth` and `web` schemas (015_web_accounts.sql),
# is dropped and replaced by the dump. There is no undo and no second
# copy; if the live database still holds anything you want, dump it first
# (`make backup`).
#
# What it does, and why each step is there:
#
#   1. Starts `db` alone and checks the archive is readable, before anything is
#      destroyed.
#   2. Stops ingest, api, mcp, web and grafana, so nothing writes to — or
#      caches from — the database while it is being replaced.
#   3. Drops the `web` and `auth` schemas (the viewer's per-user views, which
#      depend on public, and its accounts) — the dump recreates them, and a
#      schema that survived would stop pg_restore at "already exists" — then
#      drops and recreates the `public` schema WHILE TIMESCALEDB IS LIVE, so its
#      event triggers clean up hypertable chunks and continuous-aggregate
#      catalog rows properly, then reinstalls the extension. (It lives in the
#      public schema, so the drop takes it too — which is exactly the reset you
#      want, but it has to happen in that order.)
#   4. `SELECT timescaledb_pre_restore()`, which turns off the extension's DDL
#      hooks and background workers for the duration. Without it, restoring a
#      hypertable's chunks re-triggers the machinery that created them.
#   5. `pg_restore --no-owner --no-privileges`, single-threaded. NEVER pass -j:
#      parallel restore reorders work in ways TimescaleDB's restore mode does
#      not tolerate. Owners and grants are skipped on purpose — the roles are
#      cluster-level, not in a single-database dump, and the `migrate` service
#      recreates them with the passwords from .env on the next start.
#   6. `SELECT timescaledb_post_restore()`, then ANALYZE so the planner is not
#      working from empty statistics on a freshly loaded database.
#   7. `docker compose up -d`: migrate re-runs the role and time-zone scripts
#      (which is what puts the grants back), then the app services return.
#
# Restoring into a wiped volume works the same way: `docker compose down -v`,
# then run this script — it creates the extension if the fresh database has
# none. The dump carries `schema_migrations`, so the migrate service afterwards
# sees an up-to-date schema and applies nothing.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$script_dir/../.." && pwd)
server_dir=$root/server
env_file=$server_dir/.env

opt_yes=0
opt_no_start=0
# Same environment switch as scripts/bootstrap.sh, so an install that runs from
# source restores without remembering a second flag.
case ${PULS_BOOTSTRAP_BUILD:-} in
  ''|0|false|FALSE|no|NO) opt_build=0 ;;
  *) opt_build=1 ;;
esac
dump_arg=''

die() {
  printf 'restore: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

step() {
  printf '\n==> %s\n' "$*"
}

# The synopsis at the top of this file — everything above the "What it does"
# section, un-commented. Derived from the text rather than a hard-coded line
# range, so editing the header cannot silently start printing the wrong thing.
usage() {
  awk 'NR > 1 { if (!/^#/ || /^# What it does/) exit; sub(/^# ?/, ""); print }' "$0"
}

while (($# > 0)); do
  case $1 in
    --yes|-y) opt_yes=1; shift ;;
    --no-start) opt_no_start=1; shift ;;
    --build) opt_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [[ -z $dump_arg ]] || die "give exactly one dump"; dump_arg=$1; shift ;;
  esac
done

[[ -n $dump_arg ]] || { usage >&2; die "no dump given"; }
[[ -f $env_file ]] || die "$env_file does not exist; run scripts/bootstrap.sh first"
command -v docker >/dev/null 2>&1 || die "docker is required but not installed"

# No --profile here: this must never start the scheduled backup service as a
# side effect of restoring. The one call that needs the profile asks for it.
compose() {
  if [[ $opt_build == 1 ]]; then
    docker compose --project-directory "$server_dir" \
      -f "$server_dir/docker-compose.yml" -f "$server_dir/compose.build.yml" "$@"
  else
    docker compose --project-directory "$server_dir" -f "$server_dir/docker-compose.yml" "$@"
  fi
}

# Plain KEY=value lookup in .env, same rules as scripts/bootstrap.sh.
env_get() {
  local key=$1 line
  line=$( { grep -E "^${key}=" "$env_file" || true; } | tail -n 1)
  line=${line#*=}
  case $line in
    \"*\") line=${line#\"}; line=${line%\"} ;;
    \'*\') line=${line#\'}; line=${line%\'} ;;
  esac
  printf '%s' "$line"
}

pgpass=$(env_get POSTGRES_PASSWORD)
[[ -n $pgpass ]] || die "POSTGRES_PASSWORD is not set in $env_file"

# psql and pg_restore inside the running db container: no client needed on the
# host, and the tool version always matches the server.
db_psql() {
  compose exec -T -e PGPASSWORD="$pgpass" db \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

# --- where the dump comes from ------------------------------------------------
#
# Either a file on this machine, or the name of one in the backup store (the
# `backups` volume, or PULS_BACKUP_DIR), in which case a throwaway container
# streams it out. Either way it arrives on dump_source's stdout, so the restore
# is one pipeline and nothing is staged in a temporary file.

if [[ -f $dump_arg ]]; then
  source_kind=host
  dump_name=$(basename -- "$dump_arg")
elif [[ $dump_arg != */* ]]; then
  source_kind=volume
  dump_name=$dump_arg
else
  die "$dump_arg: no such file. For a dump inside the backup store give just its name (\`make backup-list\` shows them)."
fi

dump_source() {
  case $source_kind in
    host) cat -- "$dump_arg" ;;
    volume)
      docker compose --project-directory "$server_dir" --profile backup \
        -f "$server_dir/docker-compose.yml" run --rm -T backup cat "$dump_name"
      ;;
  esac
}

step "Starting the database"
compose up -d db
for _ in $(seq 1 60); do
  if compose exec -T db pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
compose exec -T db pg_isready -U postgres -d postgres >/dev/null 2>&1 \
  || die "the database did not become ready; look at: docker compose logs db"

step "Checking the dump"
[[ $source_kind != volume ]] || note "Reading $dump_name from the backup store."
# A truncated file, a plain-SQL dump or the wrong file entirely fails here,
# while the current database is still intact.
if ! dump_source | compose exec -T db pg_restore --list >/dev/null 2>&1; then
  die "$dump_name could not be read as a pg_dump custom-format archive. If you gave a name from the backup store, the line above says whether it is there at all (\`make backup-list\`)."
fi
note "$dump_name is a readable custom-format archive."

if [[ $opt_yes != 1 ]]; then
  cat <<EOF

This REPLACES the contents of the 'postgres' database in the 'pulshealth'
Compose project with $dump_name.

Everything currently in it — every sample, workout and activity summary
synced since that dump was taken — is deleted. There is no undo.

EOF
  printf 'Type "restore" to continue: '
  read -r answer
  [[ $answer == restore ]] || die "aborted"
fi

step "Stopping the app services"
compose stop ingest api mcp web grafana

step "Clearing the current schema"
# Sessions that have not noticed the stop (a Grafana pool, a psql left open)
# would block the DROP; end them first.
db_psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()" >/dev/null
# TimescaleDB is installed INTO the public schema on this image, so dropping
# the schema takes the extension with it (and timescaledb_toolkit alongside).
# That is the cleanest reset there is, and it has to happen here — while the
# extension is still live — so its event triggers dismantle hypertable chunks
# and continuous-aggregate catalog rows on the way out instead of leaving the
# catalog describing tables that no longer exist.
# The viewer's schemas go first: `web` holds views over public's tables, and
# `auth` references public.users. Both are in the dump; left in place, the
# restore's CREATE SCHEMA would fail (--exit-on-error) with public already
# gone. A dump from before 015 has neither, and the next migrate run
# recreates them empty.
db_psql -c "DROP SCHEMA IF EXISTS web CASCADE" >/dev/null
db_psql -c "DROP SCHEMA IF EXISTS auth CASCADE" >/dev/null
db_psql -c "DROP SCHEMA IF EXISTS public CASCADE" >/dev/null
db_psql -c "CREATE SCHEMA public AUTHORIZATION pg_database_owner" >/dev/null
db_psql -c "GRANT USAGE ON SCHEMA public TO public" >/dev/null
# Put timescaledb back straight away: timescaledb_pre_restore() is a function
# it provides. Everything else the dump needs (toolkit included) is in the
# dump's own CREATE EXTENSION IF NOT EXISTS lines.
db_psql -c "CREATE EXTENSION IF NOT EXISTS timescaledb" >/dev/null

step "Restoring $dump_name"
db_psql -c "SELECT timescaledb_pre_restore()" >/dev/null
restore_status=0
dump_source | compose exec -T -e PGPASSWORD="$pgpass" db \
  pg_restore --no-owner --no-privileges --exit-on-error -U postgres --dbname postgres || restore_status=$?
# post_restore must run whatever happened, or the database is left in restoring
# mode with its background workers off.
db_psql -c "SELECT timescaledb_post_restore()" >/dev/null
[[ $restore_status -eq 0 ]] \
  || die "pg_restore failed (status $restore_status). The database is in an unknown state: fix the cause and run this script again."

step "Refreshing planner statistics"
db_psql -c "ANALYZE" >/dev/null

if [[ $opt_no_start == 1 ]]; then
  note "App services left stopped (--no-start). Bring them back with: docker compose up -d"
  exit 0
fi

step "Starting the stack"
# migrate runs first: it recreates the grafana/api_reader/ingest roles with the
# passwords from .env and puts their grants back (the dump was restored without
# privileges), and re-applies PULS_TIME_ZONE.
if [[ $opt_build == 1 ]]; then
  compose up -d --build
else
  compose up -d
fi

step "Restored"
db_psql -tAc "SELECT 'quantity_samples rows: ' || count(*) FROM quantity_samples" || true
note "Check the stack with: docker compose ps; docker compose logs migrate ingest"
