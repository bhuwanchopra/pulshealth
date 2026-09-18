#!/bin/bash
# Creates/updates the scoped database roles with passwords taken from
# environment variables (see docker-compose.yml / .env):
#
#   grafana     read-only; Grafana datasource + web viewer   GRAFANA_DB_PASSWORD (required)
#               (SELECT on every table except device_tokens, which holds
#               credential hashes and is revoked on every run)
#   api_reader  read-only; product API, exact SELECT set     API_DB_PASSWORD     (required)
#   ingest      DML-only writer for the ingest server        INGEST_DB_PASSWORD  (see below)
#
# The migrate service (db/migrate.sh) runs this script on every invocation,
# i.e. on every `docker compose up -d`, with all three passwords from .env —
# Compose requires INGEST_DB_PASSWORD, and the ingest service connects as the
# `ingest` role by default. It is safe to rerun: it creates missing roles,
# rotates passwords to the current .env values and re-applies the exact
# grants, so rotating a database password is "edit .env, docker compose up -d".
#
# INGEST_DB_PASSWORD is only optional when the script is run by hand outside
# Compose: unset, it skips the ingest role and says so. Connection comes from
# PGHOST/PGPORT/PGPASSWORD in the environment (set by migrate.sh);
# POSTGRES_USER / POSTGRES_DB default to postgres/postgres.
set -euo pipefail

: "${GRAFANA_DB_PASSWORD:?GRAFANA_DB_PASSWORD must be set}"
: "${API_DB_PASSWORD:?API_DB_PASSWORD must be set}"
INGEST_DB_PASSWORD="${INGEST_DB_PASSWORD:-}"

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

psql -q -v ON_ERROR_STOP=1 \
     -v grafana_password="${GRAFANA_DB_PASSWORD}" \
     -v api_password="${API_DB_PASSWORD}" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana') THEN
    CREATE ROLE grafana LOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'api_reader') THEN
    CREATE ROLE api_reader LOGIN;
  END IF;
END
$$;

ALTER ROLE grafana LOGIN PASSWORD :'grafana_password';

-- Refuse to automate through unexpected ownership: DROP OWNED would delete
-- objects owned by this role. With ownership proven absent, it is the safest
-- way to clear every direct grant, including privileges added in new schemas.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_shdepend
    WHERE refclassid = 'pg_authid'::regclass
      AND refobjid = (SELECT oid FROM pg_roles WHERE rolname = 'api_reader')
      AND deptype = 'o'
  ) THEN
    RAISE EXCEPTION 'api_reader owns database objects; refusing automatic reconciliation';
  END IF;
END
$$;

DO $$
DECLARE
  membership record;
BEGIN
  FOR membership IN
    SELECT parent.rolname
    FROM pg_auth_members m
    JOIN pg_roles parent ON parent.oid = m.roleid
    WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = 'api_reader')
  LOOP
    EXECUTE format('REVOKE %I FROM api_reader', membership.rolname);
  END LOOP;

  FOR membership IN
    SELECT child.rolname
    FROM pg_auth_members m
    JOIN pg_roles child ON child.oid = m.member
    WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'api_reader')
  LOOP
    EXECUTE format('REVOKE api_reader FROM %I', membership.rolname);
  END LOOP;
END
$$;

DROP OWNED BY api_reader;
ALTER ROLE api_reader
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
  NOBYPASSRLS CONNECTION LIMIT -1 VALID UNTIL 'infinity'
  PASSWORD :'api_password';
ALTER ROLE api_reader RESET ALL;
ALTER ROLE api_reader IN DATABASE :"DBNAME" RESET ALL;

GRANT CONNECT ON DATABASE :"DBNAME" TO grafana;
GRANT CONNECT ON DATABASE :"DBNAME" TO api_reader;
GRANT USAGE ON SCHEMA public TO grafana;
GRANT USAGE ON SCHEMA public TO api_reader;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana;

-- pg_sequences.last_value silently reads NULL for sequences the role cannot
-- select, so the "Lookup sequence near exhaustion" alert would evaluate to 0
-- and never fire — the exact blind spot behind the 2026-08-13 outage. SELECT
-- on a sequence exposes only its current value; it grants no ability to
-- advance it (that needs UPDATE/USAGE).
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO grafana;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO grafana;

-- Continuous aggregates live in materialized hypertables under the
-- _timescaledb_internal schema; Grafana queries the user-facing view, which
-- needs read access to the backing objects.
GRANT USAGE ON SCHEMA _timescaledb_internal TO grafana;
GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_internal TO grafana;
ALTER DEFAULT PRIVILEGES IN SCHEMA _timescaledb_internal GRANT SELECT ON TABLES TO grafana;

-- device_tokens (014) holds credential hashes and per-device labels: nothing
-- a dashboard or the web viewer needs, and the one table a read-only role
-- must not hand to a dashboard editor. The blanket grant above and the
-- default privileges cover it, so revoke it here — on every run, because
-- the ALTER DEFAULT PRIVILEGES line re-grants it on a fresh install where
-- 014 is applied in the same migrate run that created the role. Guarded so
-- a baseline run on a database that predates 014 does not fail.
DO $$
BEGIN
  IF to_regclass('public.device_tokens') IS NOT NULL THEN
    REVOKE ALL ON TABLE device_tokens FROM grafana;
  END IF;
END
$$;

-- Keep product API credentials scoped to the exact current query surface.
-- `sources` names the device or app behind a raw sample and `category_labels`
-- decodes a category sample's integer value; both joined by /v1/samples and
-- /v1/sleep/daily. An install created before those endpoints picks the two up
-- on its next migrate run, because this file runs every time.
GRANT SELECT ON TABLE
  users,
  sources,
  sample_types,
  category_labels,
  quantity_samples,
  category_samples,
  workouts,
  heartbeat_series,
  ecg_samples,
  state_of_mind,
  medication_dose_events,
  activity_summaries,
  quantity_rollups,
  aggregate_series,
  aggregate_samples,
  metric_daily,
  workout_route_points,
  workout_series_points
TO api_reader;

-- Prove the direct ACL and role configuration are exact before committing.
-- PUBLIC grants from extensions may still be effective; this assertion makes
-- sure api_reader itself never receives extra privileges.
DO $$
DECLARE
  api_oid oid := (SELECT oid FROM pg_roles WHERE rolname = 'api_reader');
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE oid = api_oid
      AND rolcanlogin
      AND NOT rolsuper
      AND NOT rolinherit
      AND NOT rolcreaterole
      AND NOT rolcreatedb
      AND NOT rolreplication
      AND NOT rolbypassrls
      AND rolconnlimit = -1
      AND rolconfig IS NULL
  ) THEN
    RAISE EXCEPTION 'api_reader role attributes are not exact';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_auth_members WHERE roleid = api_oid OR member = api_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_shdepend
    WHERE refclassid = 'pg_authid'::regclass
      AND refobjid = api_oid
      AND deptype = 'o'
  ) OR EXISTS (
    SELECT 1 FROM pg_db_role_setting WHERE setrole = api_oid
  ) THEN
    RAISE EXCEPTION 'api_reader has memberships, ownership, or database settings';
  END IF;

  IF EXISTS (
    WITH expected_public(nspname, relname, privilege_type, is_grantable) AS (VALUES
      ('public', 'users', 'SELECT', false),
      ('public', 'sources', 'SELECT', false),
      ('public', 'sample_types', 'SELECT', false),
      ('public', 'category_labels', 'SELECT', false),
      ('public', 'quantity_samples', 'SELECT', false),
      ('public', 'category_samples', 'SELECT', false),
      ('public', 'workouts', 'SELECT', false),
      ('public', 'heartbeat_series', 'SELECT', false),
      ('public', 'ecg_samples', 'SELECT', false),
      ('public', 'state_of_mind', 'SELECT', false),
      ('public', 'medication_dose_events', 'SELECT', false),
      ('public', 'activity_summaries', 'SELECT', false),
      ('public', 'quantity_rollups', 'SELECT', false),
      ('public', 'aggregate_series', 'SELECT', false),
      ('public', 'aggregate_samples', 'SELECT', false),
      ('public', 'metric_daily', 'SELECT', false),
      ('public', 'workout_route_points', 'SELECT', false),
      ('public', 'workout_series_points', 'SELECT', false)
    ), allowed_hypertables(hypertable_schema, hypertable_name) AS (VALUES
      ('public', 'quantity_samples'),
      ('public', 'workout_route_points'),
      ('public', 'workout_series_points')
    ), allowed_continuous_aggregates(view_schema, view_name,
                                     materialization_hypertable_schema,
                                     materialization_hypertable_name) AS (
      SELECT
        ca.view_schema::text,
        ca.view_name::text,
        ca.materialization_hypertable_schema::text,
        ca.materialization_hypertable_name::text
      FROM timescaledb_information.continuous_aggregates ca
      JOIN allowed_hypertables ah
        ON ah.hypertable_schema = ca.hypertable_schema::text
       AND ah.hypertable_name = ca.hypertable_name::text
    ),
    -- TimescaleDB copies a hypertable's ACL onto the relations that store
    -- it, so api_reader must hold exactly SELECT on each of them and on
    -- nothing else in _timescaledb_internal. They are named through public,
    -- version-stable catalogs only — _timescaledb_catalog's layout changed
    -- between 2.27 and 2.29 and broke the previous version of this check.
    -- Two kinds of relation:
    --   1. chunks, listed by timescaledb_information.chunks;
    --   2. columnstore storage: the table holding a chunk's compressed rows
    --      (2.29: <chunk>_compressed; up to 2.28: compress_hyper_N_M_chunk
    --      under a _compressed_hypertable_N parent — an upgraded database
    --      keeps the old-style chunks, with their grants, next to new-style
    --      ones). No public view names these, so they are recognised by a
    --      structure that has been stable since compression shipped: a
    --      table in _timescaledb_internal carrying TimescaleDB's _ts_meta_*
    --      bookkeeping columns whose remaining columns are exactly the
    --      column set of one allowed hypertable. (A future hypertable with
    --      an identical column set that api_reader may not read would make
    --      this check fail loudly rather than pass silently.)
    allowed_chunks(nspname, relname) AS (
      SELECT ch.chunk_schema::text, ch.chunk_name::text
      FROM timescaledb_information.chunks ch
      JOIN allowed_hypertables ah
        ON ah.hypertable_schema = ch.hypertable_schema::text
       AND ah.hypertable_name = ch.hypertable_name::text
      UNION
      SELECT ch.chunk_schema::text, ch.chunk_name::text
      FROM timescaledb_information.chunks ch
      JOIN allowed_continuous_aggregates ca
        ON ca.materialization_hypertable_schema = ch.hypertable_schema::text
       AND ca.materialization_hypertable_name = ch.hypertable_name::text
    ), allowed_continuous_aggregate_helpers(nspname, relname) AS (
      SELECT n.nspname::text, c.relname::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN allowed_continuous_aggregates ca
        ON ca.materialization_hypertable_schema = n.nspname
      WHERE n.nspname = '_timescaledb_internal'
        AND c.relkind = 'v'
        AND c.relname IN (
          SELECT '_partial_view_' ||
                 regexp_replace(ca.materialization_hypertable_name,
                                 '^_materialized_hypertable_', '')
          FROM allowed_continuous_aggregates ca
          UNION
          SELECT '_direct_view_' ||
                 regexp_replace(ca.materialization_hypertable_name,
                                 '^_materialized_hypertable_', '')
          FROM allowed_continuous_aggregates ca
        )
        AND EXISTS (
          SELECT 1
          FROM pg_rewrite rw
          JOIN pg_depend d
            ON d.classid = 'pg_rewrite'::regclass
           AND d.objid = rw.oid
           AND d.refclassid = 'pg_class'::regclass
           AND d.refobjid <> c.oid
          JOIN pg_class rc ON rc.oid = d.refobjid
          JOIN pg_namespace rn ON rn.oid = rc.relnamespace
          WHERE rw.ev_class = c.oid
            AND EXISTS (
              SELECT 1
              FROM timescaledb_information.hypertables h
              WHERE h.hypertable_schema = rn.nspname
                AND h.hypertable_name = rc.relname
                AND EXISTS (
                  SELECT 1
                  FROM allowed_hypertables ah
                  WHERE ah.hypertable_schema = h.hypertable_schema::text
                    AND ah.hypertable_name = h.hypertable_name::text
                )
            )
        )
    ), allowed_column_sets(cols) AS (
      SELECT array_agg(a.attname::text ORDER BY a.attname)
      FROM allowed_hypertables ah
      JOIN pg_class h
        ON h.oid = format('%I.%I', ah.hypertable_schema, ah.hypertable_name)::regclass
      JOIN pg_attribute a
        ON a.attrelid = h.oid AND a.attnum > 0 AND NOT a.attisdropped
      GROUP BY h.oid
    ), allowed_columnstore(nspname, relname) AS (
      SELECT n.nspname::text, c.relname::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = '_timescaledb_internal'
        AND c.relkind = 'r'
        AND EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = c.oid AND a.attname = '_ts_meta_count')
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
             FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND a.attname NOT LIKE '\_ts\_meta\_%')
            IN (SELECT cols FROM allowed_column_sets)
    ), managed_relations(nspname, relname, privilege_type, is_grantable) AS (
      SELECT nspname, relname, 'SELECT', false FROM allowed_chunks
      UNION
      SELECT nspname, relname, 'SELECT', false FROM allowed_columnstore
      UNION
      SELECT nspname, relname, 'SELECT', false FROM allowed_continuous_aggregate_helpers
      UNION
      SELECT
        ca.materialization_hypertable_schema,
        ca.materialization_hypertable_name,
        'SELECT',
        false
      FROM allowed_continuous_aggregates ca
    ), expected AS (
      SELECT * FROM expected_public
      UNION
      SELECT * FROM managed_relations
    ), actual AS (
      SELECT n.nspname, c.relname, acl.privilege_type, acl.is_grantable
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      CROSS JOIN LATERAL aclexplode(c.relacl) acl
      WHERE acl.grantee = api_oid
        -- Up to TimescaleDB 2.28 a compressed hypertable also had a
        -- column-less parent table (_compressed_hypertable_N) that the grant
        -- hook copied the ACL to. It stores nothing (each compressed chunk
        -- carries its own columns), nothing public ties it to its
        -- hypertable, and the 2.29 extension update drops it — so
        -- non-grantable SELECT on such a table is tolerated, not required.
        AND NOT (n.nspname = '_timescaledb_internal'
                 AND c.relkind = 'r'
                 AND acl.privilege_type = 'SELECT'
                 AND NOT acl.is_grantable
                 AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                                 WHERE a.attrelid = c.oid AND a.attnum > 0
                                   AND NOT a.attisdropped))
    )
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
  ) THEN
    RAISE EXCEPTION 'api_reader relation ACL set is not exact';
  END IF;

  IF EXISTS (
    WITH expected(nspname, privilege_type, is_grantable) AS (
      VALUES ('public', 'USAGE', false)
    ), actual AS (
      SELECT n.nspname, acl.privilege_type, acl.is_grantable
      FROM pg_namespace n
      CROSS JOIN LATERAL aclexplode(n.nspacl) acl
      WHERE acl.grantee = api_oid
    )
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
  ) THEN
    RAISE EXCEPTION 'api_reader schema ACL set is not exact';
  END IF;

  IF EXISTS (
    WITH expected(datname, privilege_type, is_grantable) AS (
      VALUES (current_database(), 'CONNECT', false)
    ), actual AS (
      SELECT d.datname, acl.privilege_type, acl.is_grantable
      FROM pg_database d
      CROSS JOIN LATERAL aclexplode(d.datacl) acl
      WHERE acl.grantee = api_oid
    )
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
  ) THEN
    RAISE EXCEPTION 'api_reader database ACL set is not exact';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_attribute a
    CROSS JOIN LATERAL aclexplode(a.attacl) acl
    WHERE acl.grantee = api_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(p.proacl) acl
    WHERE acl.grantee = api_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_type t
    CROSS JOIN LATERAL aclexplode(t.typacl) acl
    WHERE acl.grantee = api_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_default_acl d
    CROSS JOIN LATERAL aclexplode(d.defaclacl) acl
    WHERE acl.grantee = api_oid
  ) THEN
    RAISE EXCEPTION 'api_reader has unexpected column, function, type, or default ACLs';
  END IF;
END
$$;

COMMIT;
EOSQL

# ---------------------------------------------------------------------------
# ingest: the scoped writer the ingest server connects as once opted in.
# ---------------------------------------------------------------------------
if [[ -z "$INGEST_DB_PASSWORD" ]]; then
  echo "099_read_roles: INGEST_DB_PASSWORD is not set; skipping the ingest role." \
       "The Compose stack always sets it (the ingest service connects as ingest);" \
       "re-run with INGEST_DB_PASSWORD exported to create or rotate the role."
  exit 0
fi

psql -q -v ON_ERROR_STOP=1 \
     -v ingest_password="${INGEST_DB_PASSWORD}" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ingest') THEN
    CREATE ROLE ingest LOGIN;
  END IF;
END
$$;

-- Same reconciliation as api_reader: refuse to continue if the role owns
-- anything (DROP OWNED would delete it), strip memberships, then DROP OWNED to
-- clear every direct grant and default privilege before re-applying the exact
-- set below. DROP OWNED also removes the role from every TimescaleDB chunk ACL
-- the earlier grants propagated to.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_shdepend
    WHERE refclassid = 'pg_authid'::regclass
      AND refobjid = (SELECT oid FROM pg_roles WHERE rolname = 'ingest')
      AND deptype = 'o'
  ) THEN
    RAISE EXCEPTION 'ingest owns database objects; refusing automatic reconciliation';
  END IF;
END
$$;

DO $$
DECLARE
  membership record;
BEGIN
  FOR membership IN
    SELECT parent.rolname
    FROM pg_auth_members m
    JOIN pg_roles parent ON parent.oid = m.roleid
    WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = 'ingest')
  LOOP
    EXECUTE format('REVOKE %I FROM ingest', membership.rolname);
  END LOOP;

  FOR membership IN
    SELECT child.rolname
    FROM pg_auth_members m
    JOIN pg_roles child ON child.oid = m.member
    WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'ingest')
  LOOP
    EXECUTE format('REVOKE ingest FROM %I', membership.rolname);
  END LOOP;
END
$$;

DROP OWNED BY ingest;
ALTER ROLE ingest
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
  NOBYPASSRLS CONNECTION LIMIT -1 VALID UNTIL 'infinity'
  PASSWORD :'ingest_password';
ALTER ROLE ingest RESET ALL;
ALTER ROLE ingest IN DATABASE :"DBNAME" RESET ALL;

-- Exactly the DML surface of server/ingest/store.go: row reads and writes on
-- the tables in public, including the ones future migrations add. No CREATE
-- on the schema and no TRUNCATE/REFERENCES/TRIGGER, so an ingest bug or a
-- leaked token cannot alter the schema, drop data wholesale, change roles, or
-- reach superuser-only paths such as COPY TO PROGRAM.
GRANT CONNECT ON DATABASE :"DBNAME" TO ingest;
GRANT USAGE ON SCHEMA public TO ingest;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ingest;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ingest;

-- The lookup tables' ids are identity columns, whose nextval runs without a
-- privilege check, so inserts need nothing here. USAGE keeps a future
-- serial/DEFAULT nextval column working; SELECT makes pg_sequences.last_value
-- readable (TestIntegration_LookupSequencesDoNotBurnOnRepeat watches it as
-- this role). No UPDATE: nothing calls setval.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ingest;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ingest;

-- InsertBatch opens every transaction with this SET LOCAL. Prove the role may
-- set it now, on every migrate run, instead of finding out as 500s on the first batch if
-- a TimescaleDB upgrade ever turns the GUC superuser-only.
SET ROLE ingest;
SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
RESET ROLE;

-- Prove the role configuration and ACL set are exact before committing. Unlike
-- api_reader, ingest legitimately holds default ACLs (tables and sequences
-- created later in public) and DML on every relation in public plus the chunks
-- and internal hypertables TimescaleDB derives from them; the checks below pin
-- those sets rather than forbid them.
DO $$
DECLARE
  ingest_oid oid := (SELECT oid FROM pg_roles WHERE rolname = 'ingest');
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE oid = ingest_oid
      AND rolcanlogin
      AND NOT rolsuper
      AND NOT rolinherit
      AND NOT rolcreaterole
      AND NOT rolcreatedb
      AND NOT rolreplication
      AND NOT rolbypassrls
      AND rolconnlimit = -1
      AND rolconfig IS NULL
  ) THEN
    RAISE EXCEPTION 'ingest role attributes are not exact';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_auth_members WHERE roleid = ingest_oid OR member = ingest_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_shdepend
    WHERE refclassid = 'pg_authid'::regclass
      AND refobjid = ingest_oid
      AND deptype = 'o'
  ) OR EXISTS (
    SELECT 1 FROM pg_db_role_setting WHERE setrole = ingest_oid
  ) THEN
    RAISE EXCEPTION 'ingest has memberships, ownership, or database settings';
  END IF;

  IF EXISTS (
    WITH expected(nspname, privilege_type, is_grantable) AS (
      VALUES ('public', 'USAGE', false)
    ), actual AS (
      SELECT n.nspname::text, acl.privilege_type, acl.is_grantable
      FROM pg_namespace n
      CROSS JOIN LATERAL aclexplode(n.nspacl) acl
      WHERE acl.grantee = ingest_oid
    )
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
  ) THEN
    RAISE EXCEPTION 'ingest schema ACL set is not exact';
  END IF;

  IF EXISTS (
    WITH expected(datname, privilege_type, is_grantable) AS (
      VALUES (current_database(), 'CONNECT', false)
    ), actual AS (
      SELECT d.datname::text, acl.privilege_type, acl.is_grantable
      FROM pg_database d
      CROSS JOIN LATERAL aclexplode(d.datacl) acl
      WHERE acl.grantee = ingest_oid
    )
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
  ) THEN
    RAISE EXCEPTION 'ingest database ACL set is not exact';
  END IF;

  -- Every relation grant must be a non-grantable DML privilege on a relation in
  -- public, or on a TimescaleDB-managed relation in _timescaledb_internal that
  -- the grant hook derived from one (chunks, compressed/materialized
  -- hypertables, continuous-aggregate helper views); or USAGE/SELECT on a
  -- sequence in public. Anything else (TRUNCATE, REFERENCES, TRIGGER,
  -- MAINTAIN, WITH GRANT OPTION, other schemas) fails the run.
  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) acl
    WHERE acl.grantee = ingest_oid
      AND NOT (
        NOT acl.is_grantable
        AND (
          (n.nspname = 'public'
             AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
             AND acl.privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE'))
          OR (n.nspname = 'public'
             AND c.relkind = 'S'
             AND acl.privilege_type IN ('USAGE', 'SELECT'))
          OR (n.nspname = '_timescaledb_internal'
             AND acl.privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
             AND (
               -- a chunk of a hypertable or of a continuous aggregate
               EXISTS (SELECT 1 FROM timescaledb_information.chunks ch
                       WHERE ch.chunk_schema = n.nspname AND ch.chunk_name = c.relname)
               -- a continuous aggregate's materialization hypertable
               OR EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates ca
                          WHERE ca.materialization_hypertable_schema = n.nspname
                            AND ca.materialization_hypertable_name = c.relname)
               -- columnstore storage of any hypertable, old or new layout
               -- (recognised as in the api_reader check above)
               OR (c.relkind = 'r'
                   AND EXISTS (SELECT 1 FROM pg_attribute a
                               WHERE a.attrelid = c.oid AND a.attname = '_ts_meta_count'))
               -- TimescaleDB <= 2.28's column-less compressed-hypertable
               -- parent (see the api_reader check above)
               OR (c.relkind = 'r'
                   AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                                   WHERE a.attrelid = c.oid AND a.attnum > 0
                                     AND NOT a.attisdropped))
               -- a continuous aggregate's partial/direct helper view: a view
               -- here that reads nothing but user hypertables or
               -- materialization hypertables. TimescaleDB's own stats views
               -- in this schema read _timescaledb_catalog and stay excluded.
               OR (c.relkind = 'v'
                   AND EXISTS (SELECT 1 FROM pg_rewrite rw WHERE rw.ev_class = c.oid)
                   AND NOT EXISTS (
                     SELECT 1
                     FROM pg_rewrite rw
                     JOIN pg_depend d
                       ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                      AND d.refclassid = 'pg_class'::regclass AND d.refobjid <> c.oid
                     JOIN pg_class rc ON rc.oid = d.refobjid
                     JOIN pg_namespace rn ON rn.oid = rc.relnamespace
                     WHERE rw.ev_class = c.oid
                       AND NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables h
                                       WHERE h.hypertable_schema = rn.nspname
                                         AND h.hypertable_name = rc.relname)
                       AND NOT EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates ca
                                       WHERE ca.materialization_hypertable_schema = rn.nspname
                                         AND ca.materialization_hypertable_name = rc.relname)))
             ))
        )
      )
  ) THEN
    RAISE EXCEPTION 'ingest relation ACL set is not exact';
  END IF;

  -- Coverage: every table, view and sequence in public carries the full set,
  -- so a new migration's table is writable the moment it is created.
  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND NOT (
        has_table_privilege(ingest_oid, c.oid, 'SELECT')
        AND has_table_privilege(ingest_oid, c.oid, 'INSERT')
        AND has_table_privilege(ingest_oid, c.oid, 'UPDATE')
        AND has_table_privilege(ingest_oid, c.oid, 'DELETE')
      )
  ) OR EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'S'
      AND NOT (
        has_sequence_privilege(ingest_oid, c.oid, 'USAGE')
        AND has_sequence_privilege(ingest_oid, c.oid, 'SELECT')
      )
  ) THEN
    RAISE EXCEPTION 'ingest is missing a DML or sequence privilege in public';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_attribute a
    CROSS JOIN LATERAL aclexplode(a.attacl) acl
    WHERE acl.grantee = ingest_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(p.proacl) acl
    WHERE acl.grantee = ingest_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_type t
    CROSS JOIN LATERAL aclexplode(t.typacl) acl
    WHERE acl.grantee = ingest_oid
  ) OR EXISTS (
    SELECT 1 FROM pg_parameter_acl p
    CROSS JOIN LATERAL aclexplode(p.paracl) acl
    WHERE acl.grantee = ingest_oid
  ) THEN
    RAISE EXCEPTION 'ingest has unexpected column, function, type, or parameter ACLs';
  END IF;

  -- Default ACLs: exactly the two declared above, granted for objects the
  -- superuser running this script creates in public.
  IF EXISTS (
    WITH expected(defaclrole, nspname, objtype, privilege_type, is_grantable) AS (VALUES
      (current_user::text, 'public', 'r', 'SELECT', false),
      (current_user::text, 'public', 'r', 'INSERT', false),
      (current_user::text, 'public', 'r', 'UPDATE', false),
      (current_user::text, 'public', 'r', 'DELETE', false),
      (current_user::text, 'public', 'S', 'USAGE', false),
      (current_user::text, 'public', 'S', 'SELECT', false)
    ), actual AS (
      SELECT r.rolname::text, n.nspname::text, d.defaclobjtype::text,
             acl.privilege_type, acl.is_grantable
      FROM pg_default_acl d
      JOIN pg_roles r ON r.oid = d.defaclrole
      LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
      CROSS JOIN LATERAL aclexplode(d.defaclacl) acl
      WHERE acl.grantee = ingest_oid
    )
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
    UNION ALL
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
  ) THEN
    RAISE EXCEPTION 'ingest default ACL set is not exact';
  END IF;
END
$$;

COMMIT;
EOSQL
