import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

const queryMock = vi.hoisted(() => vi.fn());
vi.mock("./db", () => ({ query: queryMock }));

// Passed to every query explicitly: the user is an argument, never read from
// the environment or a cookie inside lib/queries.ts.
const USER_ID = "11111111-1111-4111-8111-111111111111";

beforeAll(() => {
  process.env.DATABASE_URL = "postgres://test";
  process.env.PULS_TIME_ZONE = "America/Los_Angeles";
});

beforeEach(() => {
  queryMock.mockReset();
  queryMock.mockImplementation((text: string) => {
    // Same zone as PULS_TIME_ZONE above, so the metric_daily gate stays open
    // (its dedicated coverage lives in queries.timezone.test.ts).
    if (text.includes("puls_time_zone()")) {
      return Promise.resolve([{ zone: "America/Los_Angeles" }]);
    }
    if (text.includes("SELECT count(*)::bigint AS rows")) {
      return Promise.resolve([{ rows: "0", earliest: null, latest: null }]);
    }
    if (text.includes("FROM workouts w")) {
      return Promise.resolve([{
        uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        activity_type: "running",
        start: "0",
        end: "1",
        duration_s: 1,
        energy_kcal: null,
        distance_m: null,
        stats: {},
        stats_detail: {},
        events: [],
        activities: [],
        metadata: {},
        source: null,
      }]);
    }
    return Promise.resolve([]);
  });
});

describe("query semantics", () => {
  it("maps category types to duration and stood-only semantics", async () => {
    const { categoryAggregation } = await import("./queries");
    expect(categoryAggregation("HKCategoryTypeIdentifierSleepAnalysis")).toEqual({
      mode: "duration", unit: "h", values: [1, 3, 4, 5], dayOffsetHours: 6,
    });
    expect(categoryAggregation("HKCategoryTypeIdentifierMindfulSession")).toEqual({
      mode: "duration", unit: "min",
    });
    expect(categoryAggregation("HKCategoryTypeIdentifierAppleStandHour")).toEqual({
      mode: "count", unit: "h", values: [0],
    });
    expect(categoryAggregation("event")).toEqual({ mode: "count", unit: "count" });
  });

  it("preserves profile fields when date of birth is absent", async () => {
    const { DEFAULT_MAX_HR, profileFromStoredValues } = await import("./queries");
    expect(profileFromStoredValues(null, "female", 58)).toEqual({
      dob: null,
      biologicalSex: "female",
      age: null,
      maxHr: DEFAULT_MAX_HR,
      restingHr: 58,
    });
  });

  it("computes Today from raw local-day source totals", async () => {
    const { getTodayTotals } = await import("./queries");
    await getTodayTotals(USER_ID, ["HKQuantityTypeIdentifierStepCount"]);

    const calls = queryMock.mock.calls.filter(([sql]) => sql !== "SELECT 1");
    expect(calls.some(([sql]) => sql.includes("metric_daily"))).toBe(false);
    const [sql, params] = calls.find(([text]) => text.includes("FROM quantity_samples")) ?? [];
    expect(sql).toContain("max(total)");
    expect(sql).toContain("(now() AT TIME ZONE $3::text)::date");
    expect(params).toEqual([
      ["HKQuantityTypeIdentifierStepCount"], USER_ID, "America/Los_Angeles",
    ]);
  });

  it("deduplicates cumulative sources before coarser chart rollups", async () => {
    const { getSeries } = await import("./queries");
    await getSeries(USER_ID, "HKQuantityTypeIdentifierStepCount", "D");
    await getSeries(USER_ID, "HKQuantityTypeIdentifierStepCount", "Y");

    const calls = queryMock.mock.calls.filter(([sql]) =>
      sql.includes("WITH per_source") && sql.includes("truth AS"),
    );
    expect(calls).toHaveLength(2);
    const [intradaySql, intradayParams] = calls[0];
    expect(intradayParams.slice(0, 2)).toEqual(["1 hour", "1 hour"]);
    expect(intradayParams[4]).toBe(USER_ID);
    expect(intradaySql).toContain("GROUP BY truth_bucket");
    expect(intradaySql).toContain("sum(value)::float8 AS sum");

    const [yearSql, yearParams] = calls[1];
    expect(yearParams.slice(0, 2)).toEqual(["1 day", "1 day"]);
    expect(yearSql).toContain("time_bucket($2::interval");
    expect(yearSql).toContain("time_bucket($1::interval");
  });

  it("propagates the dynamically selected bucket for custom ranges", async () => {
    const { getSeries } = await import("./queries");
    const { resolveCustomWindow } = await import("./metrics");

    queryMock.mockImplementation((text: string) => {
      if (text.includes("puls_time_zone()")) {
        return Promise.resolve([{ zone: "America/Los_Angeles" }]);
      }
      if (text.includes("FROM aggregate_series")) {
        return Promise.resolve([{
          series_id: 7,
          agg_func: "average",
          interval_value: 1,
          interval_unit: "day",
        }]);
      }
      if (text.includes("FROM aggregate_samples")) {
        return Promise.resolve([{
          t: "1760000000000",
          value: 60,
          n: 1,
        }]);
      }
      return Promise.resolve([]);
    });

    const thirtyDayWindow = resolveCustomWindow("2026-01-01", "2026-01-30");
    const thirtyDaySeries = await getSeries(
      USER_ID,
      "HKQuantityTypeIdentifierHeartRate",
      "CUSTOM",
      thirtyDayWindow,
    );

    const aggregateThirtyDay = queryMock.mock.calls.find(([sql]) =>
      sql.includes("FROM aggregate_samples"),
    );
    expect(aggregateThirtyDay?.[1]?.[0]).toBe("1 day");
    expect(thirtyDaySeries.bucketMs).toBe(86_400_000);

    queryMock.mockClear();

    const fiveYearWindow = resolveCustomWindow("2021-01-01", "2025-12-30");
    const fiveYearSeries = await getSeries(
      USER_ID,
      "HKQuantityTypeIdentifierHeartRate",
      "CUSTOM",
      fiveYearWindow,
    );

    const aggregateFiveYear = queryMock.mock.calls.find(([sql]) =>
      sql.includes("FROM aggregate_samples"),
    );
    expect(aggregateFiveYear?.[1]?.[0]).toBe("1 month");
    expect(fiveYearSeries.bucketMs).toBe(30 * 86_400_000);
  });

  it("rejects invalid custom calendar dates", async () => {
    const { resolveCustomWindow } = await import("./metrics");

    expect(() =>
      resolveCustomWindow("2026-02-30", "2026-03-01"),
    ).toThrow("Invalid custom date range");

    expect(() =>
      resolveCustomWindow("2026-04-31", "2026-05-01"),
    ).toThrow("Invalid custom date range");

    expect(() =>
      resolveCustomWindow("2026-03-01", "2026-02-28"),
    ).toThrow("Invalid custom date range");
  });

  it("aligns chart windows to the bucket grain in the viewer's zone", async () => {
    const { getSeries } = await import("./queries");
    await getSeries(USER_ID, "HKQuantityTypeIdentifierHeartRate", "W");
    await getSeries(USER_ID, "HKQuantityTypeIdentifierStepCount", "Y");
    await getSeries(USER_ID, "HKCategoryTypeIdentifierAppleStandHour", "M");

    const windows = queryMock.mock.calls
      .map(([sql, params]) => ({ sql: sql as string, params }))
      .filter(({ sql }) => /FROM (quantity|category)_samples/.test(sql));

    expect(windows).toHaveLength(3);

    for (const { sql } of windows) {
      // Never a bare `start_ts >= $n`: that made the first day/week bucket a
      // partial slice from "now − span" to the next boundary.
      expect(sql).not.toMatch(/start_ts >= \$\d\b/);
      expect(sql).toContain("start_ts >= time_bucket(");
    }

    expect(windows[0].params).toContain("1 day");
    expect(windows[1].params).toContain("1 day");
    expect(windows[2].params).toContain("1 day");
  });

  it("attributes sleep to the wake day and dedups duration sources", async () => {
    const { getSeries } = await import("./queries");
    await getSeries(USER_ID, "HKCategoryTypeIdentifierSleepAnalysis", "M");
    await getSeries(USER_ID, "HKCategoryTypeIdentifierMindfulSession", "M");

    const [sleep, mindful] = queryMock.mock.calls
      .map(([sql]) => sql as string)
      .filter((sql) => sql.includes("FROM category_samples"));
    // 6 PM boundary: samples are shifted forward before day-bucketing, and the
    // window is widened by the same amount so the first night is whole.
    expect(sleep).toContain("c.start_ts + interval '6 hours'");
    expect(sleep).toContain(") - interval '6 hours'");
    expect(sleep).toContain("GROUP BY 1, c.source_id");
    expect(sleep).toContain("max(value)::float8 AS value");
    // Other durations are not shifted.
    expect(mindful).not.toContain("interval '6 hours'");
    expect(mindful).toContain("max(value)::float8 AS value");
  });

  it("scopes all health-data SQL and uses local Today boundaries", async () => {
    const queries = await import("./queries");
    await queries.getSeries(USER_ID, "HKQuantityTypeIdentifierStepCount", "D");
    await queries.getSeries(USER_ID, "HKCategoryTypeIdentifierAppleStandHour", "M");
    await queries.getLatestMany(USER_ID, ["HKQuantityTypeIdentifierHeartRate"]);
    await queries.getTodayTotals(USER_ID, ["HKQuantityTypeIdentifierStepCount"]);
    await queries.getActivityRings(USER_ID);
    await queries.getStats(USER_ID);
    await queries.getDailySparklines(USER_ID, ["HKQuantityTypeIdentifierStepCount"]);
    await queries.getWorkouts(USER_ID, 3);
    await queries.getWorkoutDetail(USER_ID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    await queries.getWorkoutSeries(USER_ID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    await queries.getProfile(USER_ID);

    const healthCalls = queryMock.mock.calls.filter(([sql]) =>
      /(metric_daily|quantity_samples|category_samples|activity_summaries|workouts|workout_route_points|workout_series_points|FROM users)/.test(sql),
    );
    expect(healthCalls.length).toBeGreaterThan(0);
    for (const [sql, params] of healthCalls) {
      expect(sql, sql).toMatch(/user_id|u\.id =/);
      expect(params, sql).toContain(USER_ID);
    }

    const activitySql = healthCalls.find(([sql]) => sql.includes("FROM activity_summaries"))?.[0];
    expect(activitySql).toContain("date = (now() AT TIME ZONE $2::text)::date");

    const cumulativeSql = healthCalls.find(([sql]) => sql.includes("WITH per_source") && sql.includes("truth AS"))?.[0];
    expect(cumulativeSql).toBeTruthy();
  });

  it("keeps the per-user caches apart when users alternate", async () => {
    const OTHER = "22222222-2222-4222-8222-222222222222";
    // The caches are module-scoped and earlier tests already warmed USER_ID's.
    vi.resetModules();
    const { getStats } = await import("./queries");
    const first = await getStats(USER_ID);
    const second = await getStats(OTHER);
    const firstAgain = await getStats(USER_ID);

    // Both users' scans ran, each bound to its own id, and the first user's
    // entry survived the second user's — same-instance from the TTL cache.
    const scans = queryMock.mock.calls.filter(([sql]) => sql.includes("UNION ALL"));
    expect(scans.map(([, params]) => params[0])).toEqual([USER_ID, OTHER]);
    expect(firstAgain).toBe(first);
    expect(second).not.toBe(first);
  });
});
