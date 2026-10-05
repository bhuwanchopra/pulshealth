// Sleep-stage data: category interval records grouped by wake-up day.
//
// Sleep is different from ordinary metric series: one night can contain
// overlapping records from iPhone, Apple Watch, and third-party sources.
// Establish one source as the truth for each night before aggregating.
//
// Every health-data read runs through scoped() so the database enforces the
// viewer's user boundary in accounts mode.

import { scoped } from "../db";
import { configuredTimeZone } from "../config";
import { liveRead } from "./source";
import type { SleepDay } from "../sleep";

export async function getSleepHistory(
  userId: string,
  days = 14,
  bucket = "1 day",
): Promise<SleepDay[]> {
  const empty: SleepDay[] = [];
  if (days < 0) return empty;

  return liveRead("getSleepHistory", () => empty, async () => {
    const timeZone = configuredTimeZone();

    // Attribute a night's sleep to its local wake-up day using the same
    // 18:00 boundary as the server's /v1/sleep/daily semantics.
    const dateFilter =
      "AND ($3::int = 0 OR c.start_ts >= ((((now() AT TIME ZONE $2::text)::date - $3::int)::timestamp AT TIME ZONE $2::text) - interval '6 hours'))";

    const params = [userId, timeZone, days, bucket];

    const rows = await scoped(userId, (q) =>
      q<{
        date: string;
        asleep_minutes: number;
        in_bed_minutes: number;
        core_minutes: number;
        deep_minutes: number;
        rem_minutes: number;
        unspecified_minutes: number;
        awake_minutes: number;
        nights: number;
      }>(
        `WITH per_source AS (
           SELECT
             ((c.start_ts + interval '6 hours') AT TIME ZONE $2::text)::date AS day,
             COALESCE(c.source_id, 0) AS source_id,
             sum(CASE
               WHEN cl.enum_name IN (
                 'HKCategoryValueSleepAnalysisAsleepUnspecified',
                 'HKCategoryValueSleepAnalysisAsleepCore',
                 'HKCategoryValueSleepAnalysisAsleepDeep',
                 'HKCategoryValueSleepAnalysisAsleepREM'
               )
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS asleep_minutes,
             sum(CASE
               WHEN cl.enum_name = 'HKCategoryValueSleepAnalysisInBed'
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS in_bed_minutes,
             sum(CASE
               WHEN cl.enum_name = 'HKCategoryValueSleepAnalysisAsleepCore'
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS core_minutes,
             sum(CASE
               WHEN cl.enum_name = 'HKCategoryValueSleepAnalysisAsleepDeep'
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS deep_minutes,
             sum(CASE
               WHEN cl.enum_name = 'HKCategoryValueSleepAnalysisAsleepREM'
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS rem_minutes,
             sum(CASE
               WHEN cl.enum_name = 'HKCategoryValueSleepAnalysisAsleepUnspecified'
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS unspecified_minutes,
             sum(CASE
               WHEN cl.enum_name = 'HKCategoryValueSleepAnalysisAwake'
               THEN extract(epoch FROM (c.end_ts - c.start_ts))
               ELSE 0
             END) / 60.0 AS awake_minutes
           FROM category_samples c
           JOIN sample_types st ON st.type_id = c.type_id
           JOIN category_labels cl
             ON cl.type_identifier = st.identifier
            AND cl.value = c.value
          WHERE st.identifier = 'HKCategoryTypeIdentifierSleepAnalysis'
            AND c.user_id = $1::uuid
            ${dateFilter}
            AND c.start_ts < (((now() AT TIME ZONE $2::text)::date + 1)::timestamp AT TIME ZONE $2::text)
          GROUP BY 1, 2
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (
                   PARTITION BY day
                   ORDER BY
                     asleep_minutes DESC,
                     (core_minutes + deep_minutes + rem_minutes) DESC,
                     source_id
                 ) AS rn,
                 max(in_bed_minutes) OVER (PARTITION BY day) AS max_in_bed
            FROM per_source
        ),
        daily AS (
          SELECT
            day,
            asleep_minutes,
            max_in_bed AS in_bed_minutes,
            core_minutes,
            deep_minutes,
            rem_minutes,
            unspecified_minutes,
            awake_minutes
            FROM ranked
           WHERE rn = 1
        ),
        bucketed AS (
          SELECT
            time_bucket($4::interval, day::timestamp)::date AS bucket_date,
            asleep_minutes,
            in_bed_minutes,
            core_minutes,
            deep_minutes,
            rem_minutes,
            unspecified_minutes,
            awake_minutes
            FROM daily
        )
        SELECT
          bucket_date::text AS date,
          avg(asleep_minutes)::float8 AS asleep_minutes,
          avg(in_bed_minutes)::float8 AS in_bed_minutes,
          avg(core_minutes)::float8 AS core_minutes,
          avg(deep_minutes)::float8 AS deep_minutes,
          avg(rem_minutes)::float8 AS rem_minutes,
          avg(unspecified_minutes)::float8 AS unspecified_minutes,
          avg(awake_minutes)::float8 AS awake_minutes,
          count(*)::int AS nights
          FROM bucketed
         GROUP BY bucket_date
         ORDER BY bucket_date DESC`,
        params,
      ),
    );

    return rows.map((r) => ({
      date: r.date,
      asleepMinutes: Number(r.asleep_minutes) || 0,
      inBedMinutes: Number(r.in_bed_minutes) || 0,
      coreMinutes: Number(r.core_minutes) || 0,
      deepMinutes: Number(r.deep_minutes) || 0,
      remMinutes: Number(r.rem_minutes) || 0,
      unspecifiedMinutes: Number(r.unspecified_minutes) || 0,
      awakeMinutes: Number(r.awake_minutes) || 0,
      nights: Number(r.nights) || 1,
    }));
  });
}

export async function getSleepDays(
  userId: string,
  days = 14,
): Promise<SleepDay[]> {
  return getSleepHistory(userId, days, "1 day");
}
