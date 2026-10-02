import { describe, expect, it } from "vitest";
import {
  bucketForDuration,
  defaultAgg,
  isCumulative,
  parseRange,
  RANGE_ORDER,
  RANGES,
  resolvePresetWindow,
} from "./metrics";
import { formatBucket, formatWindow, tickLabel } from "./format";

describe("metric semantics", () => {
  it("sums cumulative types and averages discrete ones", () => {
    expect(defaultAgg("HKQuantityTypeIdentifierStepCount")).toBe("sum");
    expect(defaultAgg("HKQuantityTypeIdentifierHeartRate")).toBe("avg");
  });

  it("treats UV exposure as a discrete index reading, not a daily total", () => {
    // HKQuantityTypeIdentifierUVExposure has a discrete aggregation style on
    // device; summing readings per day produced meaningless "Today" totals.
    expect(isCumulative("HKQuantityTypeIdentifierUVExposure")).toBe(false);
    expect(isCumulative("HKQuantityTypeIdentifierTimeInDaylight")).toBe(true);
  });

  it("offers all current presets", () => {
    expect(RANGE_ORDER).toEqual([
      "7D",
      "30D",
      "90D",
      "6M",
      "Y",
      "2Y",
      "5Y",
      "ALL",
      "CUSTOM",
    ]);

    for (const key of RANGE_ORDER) {
      expect(RANGES[key].key).toBe(key);
    }
  });

  it("keeps old range links working", () => {
    expect(parseRange("D")).toBe("7D");
    expect(parseRange("W")).toBe("7D");
    expect(parseRange("M")).toBe("30D");
    expect(parseRange("5Y")).toBe("5Y");
    expect(parseRange("CUSTOM")).toBe("CUSTOM");
    expect(parseRange("bogus")).toBe("7D");
    expect(parseRange(undefined)).toBe("7D");
  });

  it("uses coarse buckets for long presets", () => {
    const now = new Date("2026-09-30T12:00:00Z");
    const buckets = Object.fromEntries(
      RANGE_ORDER
        .filter((key) => key !== "ALL" && key !== "CUSTOM")
        .map((key) => [
          key,
          resolvePresetWindow(key, now)?.bucket,
        ]),
    );

    expect(buckets).toEqual({
      "7D": "1 day",
      "30D": "1 day",
      "90D": "1 day",
      "6M": "1 week",
      Y: "1 week",
      "2Y": "2 weeks",
      "5Y": "1 month",
    });
  });

  it("starts each preset at the expected time", () => {
    const now = new Date("2026-09-30T12:00:00Z");

    expect(resolvePresetWindow("7D", now)?.start).toEqual(
      new Date("2026-09-23T12:00:00Z"),
    );

    expect(resolvePresetWindow("Y", now)?.start).toEqual(
      new Date("2025-09-30T12:00:00Z"),
    );
  });

  it("starts All Time at the earliest sample and sizes its buckets to the span", () => {
    const now = new Date("2026-09-30T12:00:00Z");
    const day = 86_400_000;
    const since = (days: number) => now.getTime() - days * day;

    expect(resolvePresetWindow("ALL", now, since(60))).toEqual({
      range: "ALL",
      start: new Date(since(60)),
      end: now,
      bucket: "1 day",
      bucketMs: day,
    });

    expect(resolvePresetWindow("ALL", now, since(200))?.bucket).toBe(
      "1 week",
    );
    expect(resolvePresetWindow("ALL", now, since(600))?.bucket).toBe(
      "2 weeks",
    );
    expect(resolvePresetWindow("ALL", now, since(1500))?.bucket).toBe(
      "1 month",
    );
    expect(resolvePresetWindow("ALL", now, since(3000))?.bucket).toBe(
      "3 months",
    );

    // No samples, no window: not "the last five years".
    expect(resolvePresetWindow("ALL", now, null)).toBeNull();

    expect(bucketForDuration(90 * day).bucket).toBe("1 day");
    expect(bucketForDuration(90 * day + 1).bucket).toBe("1 week");
  });

  it("labels multi-year charts with the year", () => {
    const t = Date.UTC(2025, 0, 15, 12);

    expect(tickLabel(t, 30 * 86_400_000)).toMatch(/2025/);
    expect(tickLabel(t, 86_400_000)).not.toMatch(/2025/);
  });

  it("names a month or quarter bucket by its calendar months, not a day count", () => {
    // Buckets start at local midnight in the app's zone; pin it so the
    // instants below are bucket starts wherever the test runs.
    const prev = process.env.PULS_TIME_ZONE;
    process.env.PULS_TIME_ZONE = "UTC";

    try {
      const day = 86_400_000;

      expect(formatBucket(Date.UTC(2025, 1, 1), 30 * day)).toBe(
        "Feb 2025",
      );

      expect(
        formatBucket(Date.UTC(2025, 3, 1), 90 * day),
      ).toMatch(/^Apr\s*–\s*Jun 2025$/);

      // Weekly buckets keep their day-precise span.
      expect(
        formatBucket(Date.UTC(2025, 0, 6), 7 * day),
      ).toMatch(/^Jan 6\s*–\s*12, 2025$/);

      // A zoomed window is one range, not two bucket labels joined by a dash.
      expect(
        formatWindow(
          Date.UTC(2023, 1, 1),
          Date.UTC(2026, 1, 1),
          90 * day,
        ),
      ).toMatch(/^Feb 2023\s*–\s*Jan 2026$/);

      expect(
        formatWindow(
          Date.UTC(2025, 2, 17),
          Date.UTC(2025, 5, 2),
          7 * day,
        ),
      ).toMatch(/^Mar 17\s*–\s*Jun 1, 2025$/);
    } finally {
      if (prev === undefined) {
        delete process.env.PULS_TIME_ZONE;
      } else {
        process.env.PULS_TIME_ZONE = prev;
      }
    }
  });
});
