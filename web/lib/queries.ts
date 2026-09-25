// The single data API the UI talks to. Each function tries Postgres first.
// Every health-data function takes the user to read as its first argument;
// pages resolve it once per request with lib/viewer.ts (`viewerUser()`),
// which keeps this module free of `cookies()` and testable without a request.
//
// Demo fallback is a DEV-ONLY convenience: when running outside production
// (`NODE_ENV !== "production"`) and the database is unconfigured/unreachable,
// synthetic demo data keeps the UI populated. In production (the `web`
// container image sets NODE_ENV=production) demo data is NEVER served — a missing or
// unreachable DB surfaces as the "error" source and queries return empty
// results rather than fabricating. Live mode never fabricates either: an empty
// result stays empty.

import { cache } from "react";
import { query } from "./db";
import { typeByIdentifier } from "./catalog";
import { configuredTimeZone } from "./config";
import { defaultAgg, RANGES } from "./metrics";
import type { ResolvedSeriesWindow } from "./metrics";
import {
  demoActivityRings,
  demoLatest,
  demoProfile,
  demoSeries,
  demoStats,
  demoTodaySum,
  demoUsers,
  demoWorkoutDetail,
  demoWorkouts,
  demoWorkoutSeries,
} from "./demo";
import type {
  ActivityRingsData,
  DataSourceInfo,
  Latest,
  Profile,
  RangeKey,
  RoutePoint,
  Series,
  SeriesPoint,
  TypeStat,
  User,
  Workout,
  WorkoutActivitySegment,
  WorkoutDetail,
  WorkoutEvent,
  WorkoutSeries,
  WorkoutStat,
} from "./types";

// uuid v4-ish shape — guard before casting to ::uuid so a bad path segment
// surfaces as "not found" instead of a 500 from a failed cast.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Demo data is a dev-only convenience; production never fabricates.
const ALLOW_DEMO = process.env.NODE_ENV !== "production";

// ── data source detection (short TTL cache) ──────────────────────────────
let srcCache: { info: DataSourceInfo; at: number } | null = null;
let srcInFlight: Promise<DataSourceInfo> | null = null;
const SRC_TTL = 30_000;

export async function getDataSource(): Promise<DataSourceInfo> {
  if (!process.env.DATABASE_URL) {
    return ALLOW_DEMO
      ? { source: "demo", detail: "No DATABASE_URL set — showing demo data" }
      : { source: "error", detail: "No DATABASE_URL configured" };
  }
  if (srcCache && Date.now() - srcCache.at < SRC_TTL) return srcCache.info;
  if (srcInFlight) return srcInFlight;
  srcInFlight = checkDataSource();
  try {
    const info = await srcInFlight;
    srcCache = { info, at: Date.now() };
    return info;
  } finally {
    srcInFlight = null;
  }
}

async function checkDataSource(): Promise<DataSourceInfo> {
  let info: DataSourceInfo;
  try {
    await query("SELECT 1");
    info = { source: "live", detail: "Connected to TimescaleDB" };
  } catch (e) {
    info = ALLOW_DEMO
      ? { source: "demo", detail: "Database unreachable — showing demo data" }
      : { source: "error", detail: "Database unreachable" };
    if (!ALLOW_DEMO) console.error("[queries] database unreachable:", e);
  }
  return info;
}

// What a query should return when it can't run live: demo data in dev, or the
// supplied empty value in production (never fabricate). `src` distinguishes a
// deliberate demo session from a production error.
function notLive<T>(src: DataSourceInfo["source"], demo: () => T, empty: T): T {
  return src === "demo" ? demo() : empty;
}

async function source(): Promise<DataSourceInfo["source"]> {
  return (await getDataSource()).source;
}

// Log a given warning once per process; the zone checks below run on every
// request and would otherwise flood the log with the same line.
const warnedOnce = new Set<string>();
function warnOnce(key: string, ...args: unknown[]): void {
  if (warnedOnce.has(key)) return;
  warnedOnce.add(key);
  console.warn(...args);
}

// The database's own calendar zone. `puls_time_zone()` returns the server
// stack's PULS_TIME_ZONE (stored on the database by db/migrations/013_time_zone.sh;
// UTC when unset). metric_daily buckets its days in that zone, so its rows are
// only honest for this viewer when it equals the viewer's PULS_TIME_ZONE.
// Resolved lazily and cached at module scope. A failed lookup (database
// unreachable, or an older schema without the function) yields `null`, is
// retried after a short delay rather than on every request, and warns once.
const DB_TZ_RETRY_MS = 60_000;
let dbZoneCache: { zone: string | null; at: number } | null = null;
let dbZoneInFlight: Promise<string | null> | null = null;
async function databaseTimeZone(): Promise<string | null> {
  if (dbZoneCache && (dbZoneCache.zone !== null || Date.now() - dbZoneCache.at < DB_TZ_RETRY_MS)) {
    return dbZoneCache.zone;
  }
  if (dbZoneInFlight) return dbZoneInFlight;
  const promise = query<{ zone: string | null }>("SELECT puls_time_zone() AS zone")
    .then((rows) => {
      const zone = rows[0]?.zone;
      if (!zone) {
        warnOnce("db-zone-empty", "[queries] puls_time_zone() returned no value; metric_daily disabled");
        return null;
      }
      return zone;
    })
    .catch((e: unknown) => {
      warnOnce("db-zone-error", "[queries] could not read puls_time_zone(); metric_daily disabled:", e);
      return null;
    });
  dbZoneInFlight = promise;
  try {
    const zone = await promise;
    dbZoneCache = { zone, at: Date.now() };
    return zone;
  } finally {
    if (dbZoneInFlight === promise) dbZoneInFlight = null;
  }
}

// metric_daily's canonical day is defined in the database's zone. For a viewer
// in any other zone (or when the database's zone is unknown), raw local
// buckets are more honest than relabeling those canonical dates.
async function metricDailyUsable(): Promise<boolean> {
  const viewerZone = configuredTimeZone();
  const dbZone = await databaseTimeZone();
  if (dbZone === viewerZone) return true;
  if (dbZone !== null) {
    warnOnce(
      "db-zone-mismatch",
      `[queries] PULS_TIME_ZONE (${viewerZone}) differs from the database's puls_time_zone() (${dbZone}); ` +
        "using raw local buckets instead of metric_daily",
    );
  }
  return false;
}

// Types for which a user actually has canonical metric_daily rows. The view
// is daily-grain, so callers use it only for day-or-coarser buckets. Querying
// the view itself avoids treating min/max/mostRecent-only aggregate configs as
// daily truth. Cached briefly, per user, to avoid a round-trip per query —
// keyed by user so two people alternating in the switcher do not evict each
// other's entry.
const DAY_MS = 86_400_000;
const mdTypesCache = new Map<string, { set: Set<string>; at: number }>();
const mdTypesInFlight = new Map<string, Promise<Set<string>>>();
async function metricDailyTypes(userId: string): Promise<Set<string>> {
  if (!(await metricDailyUsable())) return new Set();
  const cached = mdTypesCache.get(userId);
  if (cached && Date.now() - cached.at < 60_000) return cached.set;
  const inFlight = mdTypesInFlight.get(userId);
  if (inFlight) return inFlight;
  const promise = query<{ identifier: string }>(
    `SELECT DISTINCT identifier FROM metric_daily WHERE user_id = $1::uuid`, [userId],
  ).then((rows) => new Set(rows.map((row) => row.identifier)));
  mdTypesInFlight.set(userId, promise);
  try {
    const set = await promise;
    mdTypesCache.set(userId, { set, at: Date.now() });
    return set;
  } finally {
    if (mdTypesInFlight.get(userId) === promise) mdTypesInFlight.delete(userId);
  }
}

// ── per-type time series ─────────────────────────────────────────────────
interface SeriesRow {
  t: string;
  sum: number | null;
  avg: number | null;
  min: number | null;
  max: number | null;
  n: number;
}

const SLEEP_ASLEEP_VALUES = [1, 3, 4, 5]; // asleepUnspecified, core, deep, rem

export type CategoryAggregation =
  | {
      mode: "duration";
      unit: "h" | "min";
      values?: number[];
      /** Shift samples forward by this many hours before day-bucketing, so a
       *  session that straddles midnight lands on one day. */
      dayOffsetHours?: number;
    }
  | { mode: "count"; unit: "count" | "h"; values?: number[] };

// Apple Health attributes a night's sleep to the day you wake up, with the
// day boundary at 6 PM: anything that starts after 18:00 belongs to the next
// calendar day. Bucketing raw stage samples by start_ts instead split every
// night across two days (23:00–00:00 on day N, the rest on N+1), so the
// dashboard headline showed only the post-midnight portion.
const SLEEP_DAY_OFFSET_HOURS = 6;

export function categoryAggregation(identifier: string): CategoryAggregation {
  if (identifier === "HKCategoryTypeIdentifierSleepAnalysis") {
    return {
      mode: "duration", unit: "h", values: SLEEP_ASLEEP_VALUES, dayOffsetHours: SLEEP_DAY_OFFSET_HOURS,
    };
  }
  if (identifier === "HKCategoryTypeIdentifierMindfulSession") {
    return { mode: "duration", unit: "min" };
  }
  if (identifier === "HKCategoryTypeIdentifierAppleStandHour") {
    return { mode: "count", unit: "h", values: [0] }; // stood only; 1 record = 1 hour
  }
  return { mode: "count", unit: "count" };
}

export async function getSeries(
  userId: string,
  identifier: string,
  range: RangeKey,
  window?: ResolvedSeriesWindow,
): Promise<Series> {
  const spec = RANGES[range];
  const type = typeByIdentifier(identifier);
  const agg = defaultAgg(identifier);
  const aggregateFunc = agg === "avg" ? "average" : "sum";
  const empty: Series = { identifier, unit: type?.unit ?? null, agg, bucketMs: spec.bucketMs, points: [] };

  const src = await source();
  if (src !== "live") return notLive(src, () => demoSeries(identifier, range), empty);

  try {
    // `from` is an instant (now − span). Every query below aligns it down to
    // the start of the bucket that contains it, in the viewer's zone, via
    // time_bucket($1, $from, $tz): otherwise the first day/week bucket held a
    // partial slice (10:37 → midnight), rendered as a low bar, and became the
    // range's "Minimum".
    const resolvedWindow: ResolvedSeriesWindow =
      window ??
      (() => {
        const end = new Date();
        const start = new Date(
          end.getTime() - (spec.spanMs ?? 5 * 365 * DAY_MS),
        );
        return {
          range: range as Exclude<RangeKey, "CUSTOM">,
          start,
          end,
          bucket: spec.bucket,
          bucketMs: spec.bucketMs,
        };
      })();

    const isCustom = resolvedWindow.range === "CUSTOM";
    const bucket = resolvedWindow.bucket;
    const bucketMs = resolvedWindow.bucketMs;
    const timeZone = configuredTimeZone();

    // Presets use exact instants. Custom ranges are calendar dates in the
    // viewer's configured timezone and use an inclusive start / exclusive end.
    const from = isCustom
      ? resolvedWindow.fromDate
      : resolvedWindow.start;

    const endExclusive = isCustom
      ? resolvedWindow.endExclusive
      : resolvedWindow.end;

    if (type?.kind === "category") {
      const category = categoryAggregation(identifier);
      const valueFilter = category.values ? "AND c.value = ANY($7::int[])" : "";
      const params = category.values
        ? [bucket, identifier, from, endExclusive, userId, timeZone, category.values]
        : [bucket, identifier, from, endExclusive, userId, timeZone];

      if (category.mode === "duration") {
        const divisor = category.unit === "h" ? 3600 : 60;
        // Code constants, not request input.
        const shift = category.dayOffsetHours ? ` + interval '${category.dayOffsetHours} hours'` : "";
        const unshift = category.dayOffsetHours ? ` - interval '${category.dayOffsetHours} hours'` : "";
        // Durations overlap across sources the same way cumulative quantities
        // do (Watch stages alongside a third-party app's asleepUnspecified),
        // so establish each bucket's truth as the highest single-source total
        // rather than summing everything.
        const rows = await query<{ t: string; value: number }>(
          `WITH per_source AS (
             SELECT time_bucket($1::interval, c.start_ts${shift}, $5::text) AS t,
                    c.source_id,
                    (sum(extract(epoch from (c.end_ts - c.start_ts))) / ${divisor}.0)::float8 AS value
               FROM category_samples c
               JOIN sample_types st ON st.type_id = c.type_id
              WHERE st.identifier = $2
                AND c.start_ts >= time_bucket(
                  $1::interval,
                  CASE
                    WHEN $3::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                      THEN ($3::date::timestamp AT TIME ZONE $6::text)
                    ELSE $3::timestamptz
                  END,
                  $6::text
                )${unshift}
                AND c.start_ts < CASE
                  WHEN $4::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                    THEN ($4::date::timestamp AT TIME ZONE $6::text)
                  ELSE $4::timestamptz
                END
                AND c.user_id = $5::uuid
                ${valueFilter}
              GROUP BY 1, c.source_id
           )
           SELECT (extract(epoch from t) * 1000)::bigint AS t,
                  max(value)::float8 AS value
             FROM per_source
            GROUP BY t ORDER BY t`,
          params,
        );
        const points: SeriesPoint[] = rows.map((r) => ({
          t: Number(r.t), value: Number(r.value), min: null, max: null, count: 0,
        }));
        return { identifier, unit: category.unit, agg: "sum", bucketMs, points };
      }

      const rows = await query<{ t: string; n: number }>(
        `SELECT (extract(epoch from time_bucket($1::interval, c.start_ts, $5::text)) * 1000)::bigint AS t,
                count(*)::int AS n
           FROM category_samples c
           JOIN sample_types st ON st.type_id = c.type_id
          WHERE st.identifier = $2
            AND c.start_ts >= time_bucket(
              $1::interval,
              CASE
                WHEN $3::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                  THEN ($3::date::timestamp AT TIME ZONE $6::text)
                ELSE $3::timestamptz
              END,
              $6::text
            )
            AND c.start_ts < CASE
              WHEN $4::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                THEN ($4::date::timestamp AT TIME ZONE $6::text)
              ELSE $4::timestamptz
            END
            AND c.user_id = $5::uuid
            ${valueFilter}
          GROUP BY 1 ORDER BY 1`,
        params,
      );
      const points: SeriesPoint[] = rows.map((r) => ({
        t: Number(r.t), value: Number(r.n), min: null, max: null, count: Number(r.n),
      }));
      return { identifier, unit: category.unit, agg: "sum", bucketMs, points };
    }

    // Prefer pre-aggregated data whenever an appropriate aggregate exists.
    //
    // Day charts use hourly aggregates when available.
    // Week/Month/6M/Year charts use daily aggregates when available and
    // re-bucket those rows to the requested chart interval.
    //
    // This keeps large charts away from quantity_samples, which can contain
    // millions of raw HealthKit samples.
    const aggregateInterval = bucketMs < DAY_MS ? "hour" : "day";

    const aggregateSeries = await query<{
      series_id: number;
      agg_func: string;
      interval_value: number;
      interval_unit: string;
    }>(
      `SELECT s.series_id,
              s.agg_func,
              s.interval_value,
              s.interval_unit
         FROM aggregate_series s
         JOIN sample_types st ON st.type_id = s.type_id
        WHERE st.identifier = $1
          AND s.agg_func = $2
          AND s.interval_value = 1
          AND s.interval_unit = $3
          AND s.device_filter = 'all'
        ORDER BY s.series_id
        LIMIT 1`,
      [identifier, aggregateFunc, aggregateInterval],
    );

    if (aggregateSeries.length) {
      const seriesId = aggregateSeries[0].series_id;

      const rows = await query<{ t: string; value: number; n: number }>(
        `SELECT
           (extract(
              epoch from time_bucket(
                $1::interval,
                a.bucket_start,
                $5::text
              )
            ) * 1000)::bigint AS t,
           ${agg === "sum"
             ? "sum(a.value)"
             : "avg(a.value)"}::float8 AS value,
           count(*)::int AS n
         FROM aggregate_samples a
        WHERE a.series_id = $2
          AND a.user_id = $3::uuid
          AND a.bucket_start >= time_bucket(
                $1::interval,
                CASE
                  WHEN $4::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                    THEN ($4::date::timestamp AT TIME ZONE $5::text)
                  ELSE $4::timestamptz
                END,
                $5::text
              )
          ${
            isCustom
              ? `AND a.bucket_start < (($6::date)::timestamp AT TIME ZONE $5::text)`
              : ""
          }
        GROUP BY 1
        ORDER BY 1`,
        isCustom
          ? [bucket, seriesId, userId, from, timeZone, endExclusive]
          : [bucket, seriesId, userId, from, timeZone],
      );

      if (rows.length) {
        const points: SeriesPoint[] = rows.map((r) => ({
          t: Number(r.t),
          value: Number(r.value) || 0,
          min: null,
          max: null,
          count: Number(r.n),
        }));

        return {
          identifier,
          unit: type?.unit ?? null,
          agg,
          bucketMs,
          points,
        };
      }
    }

    // Best-guess-of-truth view for covered types at day-or-coarser buckets.
    // metric_daily remains the fallback when no suitable aggregate exists.
    const mdTypes = await metricDailyTypes(userId);
    if (mdTypes.has(identifier) && bucketMs >= DAY_MS) {
      const rows = await query<{ t: string; value: number }>(
        `SELECT
           (extract(
              epoch from time_bucket(
                $1::interval,
                day::timestamp AT TIME ZONE $5::text,
                $5::text
              )
            ) * 1000)::bigint AS t,
           ${agg === "sum" ? "sum(value)" : "avg(value)"}::float8 AS value
         FROM metric_daily
        WHERE identifier = $2
          AND day >= (
            time_bucket(
              $1::interval,
              CASE
                WHEN $3::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                  THEN ($3::date::timestamp AT TIME ZONE $5::text)
                ELSE $3::timestamptz
              END,
              $5::text
            ) AT TIME ZONE $5::text
          )::date
          AND (
            NOT $6::boolean
            OR day < $7::date
          )
          AND user_id = $4::uuid
        GROUP BY 1 ORDER BY 1`,
        [
          bucket,
          identifier,
          from,
          userId,
          timeZone,
          isCustom,
          endExclusive,
        ],
      );

      const points: SeriesPoint[] = rows.map((r) => ({
        t: Number(r.t),
        value: Number(r.value) || 0,
        min: null,
        max: null,
        count: 0,
      }));

      return {
        identifier,
        unit: type?.unit ?? null,
        agg,
        bucketMs,
        points,
      };
    }


    // Raw cumulative samples often overlap across iPhone and Watch. Establish
    // truth at the requested intraday grain, or at local-day grain for longer
    // charts, by choosing the highest source total. Only then roll those truth
    // values into the requested bucket, so a week can use a different winning
    // source on each day.
    const truthBucket = bucketMs < DAY_MS ? bucket : "1 day";
    const rows = agg === "sum"
      ? await query<SeriesRow>(
        `WITH per_source AS (
           SELECT time_bucket($2::interval, q.start_ts, $6::text) AS truth_bucket,
                  q.source_id,
                  sum(q.value)::float8 AS value
             FROM quantity_samples q
             JOIN sample_types st ON st.type_id = q.type_id
            WHERE st.identifier = $3
              AND q.start_ts >= time_bucket(
                $1::interval,
                CASE
                  WHEN $4::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                    THEN ($4::date::timestamp AT TIME ZONE $6::text)
                  ELSE $4::timestamptz
                END,
                $6::text
              )
              AND q.user_id = $5::uuid
	      ${isCustom ? `AND q.start_ts < (($7::date)::timestamp AT TIME ZONE $6::text)` : ""}
            GROUP BY 1, q.source_id
         ), truth AS (
           SELECT truth_bucket, max(value)::float8 AS value
             FROM per_source
            GROUP BY truth_bucket
         )
         SELECT (extract(epoch from time_bucket($1::interval, truth_bucket, $6::text)) * 1000)::bigint AS t,
                sum(value)::float8 AS sum,
                NULL::float8 AS avg,
                NULL::float8 AS min,
                NULL::float8 AS max,
                count(*)::int AS n
           FROM truth
          GROUP BY time_bucket($1::interval, truth_bucket, $6::text)
          ORDER BY time_bucket($1::interval, truth_bucket, $6::text)`,
	isCustom
	  ? [bucket, truthBucket, identifier, from, userId, timeZone, endExclusive]
	    : [bucket, truthBucket, identifier, from, userId, timeZone],
      )
      : await query<SeriesRow>(
        `SELECT (extract(epoch from time_bucket($1::interval, q.start_ts, $5::text)) * 1000)::bigint AS t,
                sum(q.value)::float8 AS sum,
                avg(q.value)::float8 AS avg,
                min(q.value)::float8 AS min,
                max(q.value)::float8 AS max,
                count(*)::int AS n
           FROM quantity_samples q
           JOIN sample_types st ON st.type_id = q.type_id
          WHERE st.identifier = $2
            AND q.start_ts >= time_bucket($1::interval, CASE
                  WHEN $3::text ~ '^\\d{4}-\\d{2}-\\d{2}$'
                    THEN ($3::date::timestamp AT TIME ZONE $5::text)
                  ELSE $3::timestamptz
                END,
                $5::text)
            AND q.user_id = $4::uuid
	    ${isCustom ? `AND q.start_ts < (($6::date)::timestamp AT TIME ZONE $5::text)` : ""}
          GROUP BY 1 ORDER BY 1`,
	  isCustom
	    ? [bucket, identifier, from, userId, timeZone, endExclusive]
	      : [bucket, identifier, from, userId, timeZone],
      );

    const points: SeriesPoint[] = rows.map((r) => ({
      t: Number(r.t),
      value: Number(agg === "sum" ? r.sum : r.avg) || 0,
      min: r.min == null ? null : Number(r.min),
      max: r.max == null ? null : Number(r.max),
      count: Number(r.n),
    }));

    return {
      identifier,
      unit: type?.unit ?? null,
      agg,
      bucketMs,
      points,
    };
  } catch (e) {
    console.error("[queries] getSeries failed:", e);
    return ALLOW_DEMO ? demoSeries(identifier, range) : empty;
  }
}

// ── latest reading per type ──────────────────────────────────────────────
export async function getLatestMany(userId: string, identifiers: string[]): Promise<Map<string, Latest>> {
  const out = new Map<string, Latest>();
  if (!identifiers.length) return out;

  const src = await source();
  if (src !== "live") {
    if (src === "demo") for (const id of identifiers) out.set(id, demoLatest(id));
    return out;
  }

  try {
    const rows = await query<{ identifier: string; value: number; t: string }>(
      `SELECT DISTINCT ON (st.identifier)
              st.identifier, q.value::float8 AS value,
              (extract(epoch from q.start_ts) * 1000)::bigint AS t
         FROM quantity_samples q
         JOIN sample_types st ON st.type_id = q.type_id
        WHERE st.identifier = ANY($1::text[])
          AND q.user_id = $2::uuid
        ORDER BY st.identifier, q.start_ts DESC`,
      [identifiers, userId],
    );
    for (const r of rows) {
      out.set(r.identifier, {
        identifier: r.identifier,
        value: Number(r.value),
        unit: typeByIdentifier(r.identifier)?.unit ?? null,
        t: Number(r.t),
      });
    }
    return out;
  } catch (e) {
    console.error("[queries] getLatestMany failed:", e);
    if (ALLOW_DEMO) for (const id of identifiers) out.set(id, demoLatest(id));
    return out;
  }
}

// ── today's cumulative totals (for activity rings / summary) ──────────────
export async function getTodayTotals(userId: string, identifiers: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  if (!identifiers.length) return out;

  const src = await source();
  if (src !== "live") {
    for (const id of identifiers) out.set(id, src === "demo" ? demoTodaySum(id) : 0);
    return out;
  }

  try {
    for (const id of identifiers) out.set(id, 0);
    const timeZone = configuredTimeZone();

    // Read Today directly from raw local-day samples so the live headline does
    // not depend on aggregate refresh or bucket-settlement timing. Choose one
    // source per type to avoid overlapping Watch/phone totals.
    const rows = await query<{ identifier: string; total: number }>(
      `WITH per_source AS (
         SELECT st.identifier, q.source_id, sum(q.value)::float8 AS total
           FROM quantity_samples q
           JOIN sample_types st ON st.type_id = q.type_id
          WHERE st.identifier = ANY($1::text[])
            AND q.user_id = $2::uuid
            AND q.start_ts >= ((now() AT TIME ZONE $3::text)::date AT TIME ZONE $3::text)
            AND q.start_ts < (((now() AT TIME ZONE $3::text)::date + 1) AT TIME ZONE $3::text)
          GROUP BY st.identifier, q.source_id
       )
       SELECT identifier, max(total)::float8 AS total
         FROM per_source
        GROUP BY identifier`,
      [identifiers, userId, timeZone],
    );
    for (const r of rows) out.set(r.identifier, Number(r.total));
    return out;
  } catch (e) {
    console.error("[queries] getTodayTotals failed:", e);
    for (const id of identifiers) out.set(id, ALLOW_DEMO ? demoTodaySum(id) : 0);
    return out;
  }
}

// ── activity rings (today's HKActivitySummary) ───────────────────────────
export async function getActivityRings(userId: string): Promise<ActivityRingsData> {
  // Apple's standard goals stand in for any null goal column.
  const fallback: ActivityRingsData = {
    date: null, moveMode: 0,
    moveKcal: 0, moveGoalKcal: 600,
    exerciseMin: 0, exerciseGoalMin: 30,
    standHours: 0, standGoalHours: 12,
    moveTimeMin: null, moveTimeGoalMin: null,
    hasData: false,
  };

  const src = await source();
  if (src !== "live") return notLive(src, () => demoActivityRings(), fallback);

  try {
    const rows = await query<{
      date: string;
      move_kcal: number | null;
      move_goal_kcal: number | null;
      exercise_min: number | null;
      exercise_goal_min: number | null;
      stand_hours: number | null;
      stand_goal_hours: number | null;
      move_mode: number | null;
      move_time_min: number | null;
      move_time_goal_min: number | null;
    }>(
      `SELECT (extract(epoch from (date::timestamp AT TIME ZONE $2::text)) * 1000)::bigint AS date,
              move_kcal::float8, move_goal_kcal::float8,
              exercise_min::float8, exercise_goal_min::float8,
              stand_hours::float8, stand_goal_hours::float8,
              move_mode, move_time_min::float8, move_time_goal_min::float8
         FROM activity_summaries
        WHERE user_id = $1::uuid
          AND date = (now() AT TIME ZONE $2::text)::date
        LIMIT 1`,
      [userId, configuredTimeZone()],
    );
    if (!rows.length) return fallback;
    const r = rows[0];
    return {
      date: Number(r.date),
      moveMode: r.move_mode === 1 ? 1 : 0,
      moveKcal: Number(r.move_kcal ?? 0),
      moveGoalKcal: Number(r.move_goal_kcal ?? 600),
      exerciseMin: Number(r.exercise_min ?? 0),
      exerciseGoalMin: Number(r.exercise_goal_min ?? 30),
      standHours: Number(r.stand_hours ?? 0),
      standGoalHours: Number(r.stand_goal_hours ?? 12),
      moveTimeMin: r.move_time_min == null ? null : Number(r.move_time_min),
      moveTimeGoalMin: r.move_time_goal_min == null ? null : Number(r.move_time_goal_min),
      hasData: true,
    };
  } catch (e) {
    console.error("[queries] getActivityRings failed:", e);
    return ALLOW_DEMO ? demoActivityRings() : fallback;
  }
}

// ── catalog-wide stats (rows + date range per type) ──────────────────────
// Cached per user for a short TTL (the scan is the heaviest query here).
const STATS_TTL = 30_000;
const statsCache = new Map<string, { value: Map<string, TypeStat>; at: number }>();
const statsInFlight = new Map<string, Promise<Map<string, TypeStat>>>();

export async function getStats(userId: string): Promise<Map<string, TypeStat>> {
  const cached = statsCache.get(userId);
  if (cached && Date.now() - cached.at < STATS_TTL) return cached.value;
  const inFlight = statsInFlight.get(userId);
  if (inFlight) return inFlight;
  const promise = loadStats(userId);
  statsInFlight.set(userId, promise);
  try {
    const value = await promise;
    statsCache.set(userId, { value, at: Date.now() });
    return value;
  } finally {
    if (statsInFlight.get(userId) === promise) statsInFlight.delete(userId);
  }
}

async function loadStats(userId: string): Promise<Map<string, TypeStat>> {
  const out = new Map<string, TypeStat>();

  const src = await source();
  if (src !== "live") {
    if (src === "demo") for (const s of demoStats()) out.set(s.identifier, s);
    return out;
  }

  try {
    const rows = await query<{ identifier: string; rows: string; earliest: string | null; latest: string | null }>(
      `SELECT st.identifier,
              count(*)::bigint AS rows,
              (extract(epoch from min(x.start_ts)) * 1000)::bigint AS earliest,
              (extract(epoch from max(x.start_ts)) * 1000)::bigint AS latest
         FROM (
           SELECT type_id, start_ts FROM quantity_samples WHERE user_id = $1::uuid
           UNION ALL
           SELECT type_id, start_ts FROM category_samples WHERE user_id = $1::uuid
         ) x
         JOIN sample_types st ON st.type_id = x.type_id
        GROUP BY st.identifier`,
      [userId],
    );
    for (const r of rows) {
      out.set(r.identifier, {
        identifier: r.identifier,
        rows: Number(r.rows),
        earliest: r.earliest == null ? null : Number(r.earliest),
        latest: r.latest == null ? null : Number(r.latest),
      });
    }
    // Workouts live in their own table.
    const wk = await query<{ rows: string; earliest: string | null; latest: string | null }>(
      `SELECT count(*)::bigint AS rows,
              (extract(epoch from min(start_ts)) * 1000)::bigint AS earliest,
              (extract(epoch from max(start_ts)) * 1000)::bigint AS latest
         FROM workouts
        WHERE user_id = $1::uuid`,
      [userId],
    );
    if (wk[0] && Number(wk[0].rows) > 0) {
      out.set("HKWorkoutTypeIdentifier", {
        identifier: "HKWorkoutTypeIdentifier",
        rows: Number(wk[0].rows),
        earliest: wk[0].earliest == null ? null : Number(wk[0].earliest),
        latest: wk[0].latest == null ? null : Number(wk[0].latest),
      });
    }
    return out;
  } catch (e) {
    console.error("[queries] getStats failed:", e);
    if (ALLOW_DEMO) for (const s of demoStats()) out.set(s.identifier, s);
    return out;
  }
}

// ── batched daily sparklines for a set of quantity types (one round-trip) ──
export async function getDailySparklines(userId: string, identifiers: string[], days = 21): Promise<Map<string, number[]>> {
  const out = new Map<string, number[]>();
  if (!identifiers.length) return out;

  const src = await source();
  if (src !== "live") {
    if (src === "demo") {
      for (const id of identifiers) {
        out.set(id, demoSeries(id, "M").points.slice(-days).map((p) => p.value));
      }
    }
    return out;
  }

  try {
    const byId = new Map<string, number[]>();
    const mdTypes = await metricDailyTypes(userId);
    const mdIds = identifiers.filter((id) => mdTypes.has(id));
    const rawIds = identifiers.filter((id) => !mdTypes.has(id));
    const rawCumIds = rawIds.filter((id) => defaultAgg(id) === "sum");
    const rawDiscIds = rawIds.filter((id) => defaultAgg(id) === "avg");
    const timeZone = configuredTimeZone();

    // Covered types: daily best-guess-of-truth.
    if (mdIds.length) {
      const rows = await query<{ identifier: string; value: number }>(
        `SELECT identifier,
                (extract(epoch from (day::timestamp AT TIME ZONE $4::text)) * 1000)::bigint AS t,
                value::float8 AS value
           FROM metric_daily
          WHERE identifier = ANY($1::text[])
            AND user_id = $3::uuid
            AND day >= (now() AT TIME ZONE $4::text)::date - $2::int
          ORDER BY identifier, day`,
        [mdIds, days, userId, timeZone],
      );
      for (const r of rows) {
        const arr = byId.get(r.identifier) ?? [];
        arr.push(Number(r.value) || 0);
        byId.set(r.identifier, arr);
      }
    }

    // Cumulative raw data: one source per local day to avoid Watch + phone
    // double counts. Discrete readings remain a cross-source average.
    if (rawCumIds.length) {
      const rows = await query<{ identifier: string; value: number }>(
        `WITH per_source AS (
           SELECT st.identifier,
                  time_bucket('1 day', q.start_ts, $4::text) AS day,
                  q.source_id,
                  sum(q.value)::float8 AS value
             FROM quantity_samples q
             JOIN sample_types st ON st.type_id = q.type_id
            WHERE st.identifier = ANY($1::text[])
              AND q.user_id = $3::uuid
              AND q.start_ts >= (((now() AT TIME ZONE $4::text)::date - $2::int) AT TIME ZONE $4::text)
            GROUP BY st.identifier, day, q.source_id
         )
         SELECT identifier, max(value)::float8 AS value
           FROM per_source
          GROUP BY identifier, day
          ORDER BY identifier, day`,
        [rawCumIds, days, userId, timeZone],
      );
      for (const r of rows) {
        const arr = byId.get(r.identifier) ?? [];
        arr.push(Number(r.value) || 0);
        byId.set(r.identifier, arr);
      }
    }

    if (rawDiscIds.length) {
      const rows = await query<{ identifier: string; value: number }>(
        `SELECT st.identifier, avg(q.value)::float8 AS value
           FROM quantity_samples q
           JOIN sample_types st ON st.type_id = q.type_id
          WHERE st.identifier = ANY($1::text[])
            AND q.user_id = $3::uuid
            AND q.start_ts >= (((now() AT TIME ZONE $4::text)::date - $2::int) AT TIME ZONE $4::text)
          GROUP BY st.identifier, time_bucket('1 day', q.start_ts, $4::text)
          ORDER BY st.identifier, time_bucket('1 day', q.start_ts, $4::text)`,
        [rawDiscIds, days, userId, timeZone],
      );
      for (const r of rows) {
        const arr = byId.get(r.identifier) ?? [];
        arr.push(Number(r.value) || 0);
        byId.set(r.identifier, arr);
      }
    }

    for (const id of identifiers) out.set(id, byId.get(id) ?? []);
    return out;
  } catch (e) {
    console.error("[queries] getDailySparklines failed:", e);
    if (ALLOW_DEMO) {
      for (const id of identifiers) {
        out.set(id, demoSeries(id, "M").points.slice(-days).map((p) => p.value));
      }
    }
    return out;
  }
}

// ── workouts ─────────────────────────────────────────────────────────────
export async function getWorkouts(userId: string, limit = 40): Promise<Workout[]> {
  const src = await source();
  if (src !== "live") return notLive(src, () => demoWorkouts(limit), []);
  try {
    const rows = await query<{
      uuid: string;
      activity_type: string;
      start: string;
      end: string;
      duration_s: number | null;
      energy_kcal: number | null;
      distance_m: number | null;
    }>(
      `SELECT uuid::text,
              activity_type,
              (extract(epoch from start_ts) * 1000)::bigint AS start,
              (extract(epoch from end_ts) * 1000)::bigint AS end,
              duration_s::float8,
              energy_kcal::float8,
              distance_m::float8
         FROM workouts
        WHERE user_id = $2::uuid
        ORDER BY start_ts DESC
        LIMIT $1`,
      [limit, userId],
    );
    if (!rows.length) return [];
    return rows.map((r) => ({
      uuid: r.uuid,
      activityType: r.activity_type || "Workout",
      start: Number(r.start),
      end: Number(r.end),
      durationS: Number(r.duration_s ?? 0),
      energyKcal: r.energy_kcal == null ? null : Number(r.energy_kcal),
      distanceM: r.distance_m == null ? null : Number(r.distance_m),
    }));
  } catch (e) {
    console.error("[queries] getWorkouts failed:", e);
    return ALLOW_DEMO ? demoWorkouts(limit) : [];
  }
}

// ── one workout + its route ───────────────────────────────────────────────
// React-cached per request on (userId, uuid): generateMetadata and the page
// both ask for the same workout.
export const getWorkoutDetail = cache(async function getWorkoutDetail(userId: string, uuid: string): Promise<WorkoutDetail | null> {
  const src = await source();
  if (src !== "live") return notLive(src, () => demoWorkoutDetail(uuid), null);

  // A non-uuid path segment can never match a live row; skip the query (and
  // the cast error) and report not-found.
  if (!UUID_RE.test(uuid)) return null;

  try {
    const rows = await query<{
      uuid: string;
      activity_type: string;
      start: string;
      end: string;
      duration_s: number | null;
      energy_kcal: number | null;
      distance_m: number | null;
      stats: Record<string, number> | null;
      stats_detail: Record<string, WorkoutStat> | null;
      events: WorkoutEvent[] | null;
      activities: RawActivity[] | null;
      metadata: Record<string, unknown> | null;
      source: string | null;
    }>(
      `SELECT w.uuid::text,
              w.activity_type,
              (extract(epoch from w.start_ts) * 1000)::bigint AS start,
              (extract(epoch from w.end_ts) * 1000)::bigint AS end,
              w.duration_s::float8,
              w.energy_kcal::float8,
              w.distance_m::float8,
              w.stats,
              w.stats_detail,
              w.events,
              w.activities,
              w.metadata,
              s.name AS source
         FROM workouts w
         LEFT JOIN sources s ON s.source_id = w.source_id
        WHERE w.uuid = $1::uuid
          AND w.user_id = $2::uuid`,
      [uuid, userId],
    );
    const r = rows[0];
    if (!r) return null;

    const routeRows = await query<{
      t: string;
      lat: number;
      lon: number;
      altitude_m: number | null;
      speed_mps: number | null;
    }>(
      `SELECT (extract(epoch from ts) * 1000)::bigint AS t,
              lat::float8, lon::float8, altitude_m::float8, speed_mps::float8
         FROM workout_route_points
        WHERE workout_uuid = $1::uuid
          AND user_id = $2::uuid
        ORDER BY ts`,
      [uuid, userId],
    );
    const route: RoutePoint[] = routeRows.map((p) => ({
      t: Number(p.t),
      lat: Number(p.lat),
      lon: Number(p.lon),
      altitude: p.altitude_m == null ? null : Number(p.altitude_m),
      speed: p.speed_mps == null ? null : Number(p.speed_mps),
    }));

    const activities: WorkoutActivitySegment[] = (r.activities ?? []).map((a) => ({
      activityType: a.activityType || "Workout",
      start: Number(a.start),
      end: a.end == null ? null : Number(a.end),
      durationS: Number(a.duration ?? 0),
      statistics: a.statistics ?? {},
    }));

    return {
      uuid: r.uuid,
      activityType: r.activity_type || "Workout",
      start: Number(r.start),
      end: Number(r.end),
      durationS: Number(r.duration_s ?? 0),
      energyKcal: r.energy_kcal == null ? null : Number(r.energy_kcal),
      distanceM: r.distance_m == null ? null : Number(r.distance_m),
      stats: r.stats ?? {},
      statsDetail: r.stats_detail ?? {},
      events: r.events ?? [],
      activities,
      metadata: r.metadata ?? {},
      source: r.source,
      route,
    };
  } catch (e) {
    console.error("[queries] getWorkoutDetail failed:", e);
    return ALLOW_DEMO ? demoWorkoutDetail(uuid) : null;
  }
});

// Raw activity shape as stored in the workouts.activities jsonb (Swift field
// names: `duration` in seconds).
interface RawActivity {
  activityType: string;
  start: number;
  end: number | null;
  duration: number;
  statistics: Record<string, WorkoutStat> | null;
}

// ── one workout's intra-workout series streams ────────────────────────────
export async function getWorkoutSeries(userId: string, uuid: string): Promise<WorkoutSeries[]> {
  const src = await source();
  if (src !== "live") return notLive(src, () => demoWorkoutSeries(uuid), []);
  if (!UUID_RE.test(uuid)) return [];
  try {
    const rows = await query<{ identifier: string; unit: string | null; t: string; value: number }>(
      `SELECT st.identifier,
              st.unit,
              (extract(epoch from p.ts) * 1000)::bigint AS t,
              p.value::float8
         FROM workout_series_points p
         JOIN sample_types st ON st.type_id = p.type_id
        WHERE p.workout_uuid = $1::uuid
          AND p.user_id = $2::uuid
        ORDER BY st.identifier, p.ts`,
      [uuid, userId],
    );
    const byType = new Map<string, WorkoutSeries>();
    for (const r of rows) {
      let s = byType.get(r.identifier);
      if (!s) {
        s = { type: r.identifier, unit: r.unit, points: [] };
        byType.set(r.identifier, s);
      }
      s.points.push({ t: Number(r.t), value: Number(r.value) });
    }
    return [...byType.values()];
  } catch (e) {
    console.error("[queries] getWorkoutSeries failed:", e);
    return ALLOW_DEMO ? demoWorkoutSeries(uuid) : [];
  }
}

// ── the users the database holds (for the switcher) ──────────────────────
// Oldest first, so the seeded default user — created by migration 000 before
// any phone syncs — leads the list. Name and email are null until the
// phone's first {"profile":…} line lands.
export async function getUsers(): Promise<User[]> {
  const src = await source();
  if (src !== "live") return notLive(src, demoUsers, []);
  try {
    const rows = await query<{ id: string; name: string | null; email: string | null }>(
      `SELECT id::text AS id, name, email
         FROM users
        ORDER BY created_at, id`,
    );
    return rows.map((r) => ({ id: r.id, name: r.name, email: r.email }));
  } catch (e) {
    console.error("[queries] getUsers failed:", e);
    return ALLOW_DEMO ? demoUsers() : [];
  }
}

// ── user profile (DOB/max HR + resting HR for HRR zones) ──────────────────
export const DEFAULT_MAX_HR = 190;

export async function getProfile(userId: string): Promise<Profile> {
  const fallback: Profile = { dob: null, biologicalSex: null, age: null, maxHr: DEFAULT_MAX_HR, restingHr: null };
  const src = await source();
  if (src !== "live") return notLive(src, demoProfile, fallback);
  try {
    const rows = await query<{ dob: string | null; biological_sex: string | null; resting_hr: number | null }>(
      `SELECT (extract(epoch from (u.dob::timestamp AT TIME ZONE $2::text)) * 1000)::bigint AS dob,
              u.biological_sex,
              r.value::float8 AS resting_hr
         FROM users u
         LEFT JOIN LATERAL (
           SELECT q.value
             FROM quantity_samples q
             JOIN sample_types st ON st.type_id = q.type_id
            WHERE q.user_id = u.id
              AND st.identifier = 'HKQuantityTypeIdentifierRestingHeartRate'
            ORDER BY q.start_ts DESC
            LIMIT 1
         ) r ON true
        WHERE u.id = $1::uuid`,
      [userId, configuredTimeZone()],
    );
    const r = rows[0];
    if (!r) return fallback;
    const restingHr = r.resting_hr == null ? null : Number(r.resting_hr);
    return profileFromStoredValues(
      r.dob == null ? null : Number(r.dob),
      r.biological_sex,
      restingHr,
    );
  } catch (e) {
    console.error("[queries] getProfile failed:", e);
    return ALLOW_DEMO ? demoProfile() : fallback;
  }
}

export function profileFromStoredValues(
  dobMs: number | null,
  sex: string | null,
  restingHr: number | null,
): Profile {
  if (dobMs == null) {
    return { dob: null, biologicalSex: sex, age: null, maxHr: DEFAULT_MAX_HR, restingHr };
  }
  return profileFromDob(dobMs, sex, restingHr);
}

// Build a Profile from an epoch-ms DOB: age today, max HR = 220 − age.
export function profileFromDob(
  dobMs: number,
  sex: string | null,
  restingHr: number | null = null,
  now = new Date(),
  timeZone = configuredTimeZone(),
): Profile {
  const parts = (date: Date) => Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      year: "numeric", month: "numeric", day: "numeric", timeZone,
    }).formatToParts(date).filter((part) => part.type !== "literal").map((part) => [part.type, Number(part.value)]),
  ) as Record<"year" | "month" | "day", number>;
  const today = parts(now);
  const dob = parts(new Date(dobMs));
  let age = today.year - dob.year;
  if (today.month < dob.month || (today.month === dob.month && today.day < dob.day)) age--;
  const valid = age >= 0 && age < 120;
  return {
    dob: dobMs,
    biologicalSex: sex,
    age: valid ? age : null,
    maxHr: valid ? 220 - age : DEFAULT_MAX_HR,
    restingHr,
  };
}
