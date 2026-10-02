#!/usr/bin/env bash
# The web viewer's getStats() query uses quantity_rollups directly (through
# web/lib/queries.ts). Keep that relation inside the same per-user view surface
# as metric_daily. This is a separate every-run reconciliation because 099
# intentionally DROP OWNEDs web_app on every invocation before re-applying its
# exact grants.
set -euo pipefail

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

if [[ -z "${WEB_DB_PASSWORD:-}" ]]; then
  exit 0
fi

# 015 may not exist on a database that has not reached the accounts migration.
if [[ "$(psql -X -q -tA --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
          -c "SELECT to_regnamespace('web') IS NOT NULL AND to_regclass('public.quantity_rollups') IS NOT NULL AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_app')")" != t ]]; then
  exit 0
fi

psql -X -q -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
BEGIN;

DROP VIEW IF EXISTS web.quantity_rollups;

CREATE VIEW web.quantity_rollups WITH (security_barrier) AS
  SELECT *
    FROM public.quantity_rollups
   WHERE user_id = (SELECT puls_viewer_user());

GRANT SELECT ON TABLE web.quantity_rollups TO web_app;

COMMIT;
EOSQL
