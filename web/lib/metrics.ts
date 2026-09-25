import type { RangeKey } from "./types";

// HealthKit aggregationStyle isn't ported to the web catalog, so we classify
// cumulative ("how much over the period" → sum) vs discrete ("what was the
// reading" → avg) by identifier. Substring match keeps this robust as the
// catalog grows.
const CUMULATIVE_HINTS = [
  "StepCount",
  "DistanceWalkingRunning",
  "DistanceCycling",
  "DistanceSwimming",
  "DistanceWheelchair",
  "DistanceDownhillSnowSports",
  "DistanceCrossCountrySkiing",
  "DistancePaddleSports",
  "DistanceRowing",
  "DistanceSkatingSports",
  "FlightsClimbed",
  "ActiveEnergyBurned",
  "BasalEnergyBurned",
  "AppleExerciseTime",
  "AppleStandTime",
  "AppleMoveTime",
  "SwimmingStrokeCount",
  "PushCount",
  "NikeFuel",
  "NumberOfTimesFallen",
  "NumberOfAlcoholicBeverages",
  "Dietary",
  "InhalerUsage",
  // Not UVExposure: HealthKit's aggregation style for it is discrete (a UV
  // index reading), so summing readings per day is meaningless.
  "TimeInDaylight",
  "AppleSleepingBreathingDisturbances",
];

export function isCumulative(identifier: string): boolean {
  return CUMULATIVE_HINTS.some((h) => identifier.includes(h));
}

export function defaultAgg(identifier: string): "sum" | "avg" {
  return isCumulative(identifier) ? "sum" : "avg";
}

export interface RangeSpec {
  key: RangeKey;
  label: string;
  /** how far back from now, in ms; null means "all available" */
  spanMs: number | null;
  /** Postgres time_bucket interval literal */
  bucket: string;
  bucketMs: number;
}

const HOUR = 3600_000;
const DAY = 86_400_000;
const WEEK = 7 * DAY;
const MONTH = 30 * DAY;

export function bucketForDuration(durationMs: number): {
  bucket: string;
  bucketMs: number;
} {
  if (durationMs <= 90 * DAY) {
    return { bucket: "1 day", bucketMs: DAY };
  }
  if (durationMs <= 365 * DAY) {
    return { bucket: "1 week", bucketMs: WEEK };
  }
  if (durationMs <= 730 * DAY) {
    return { bucket: "2 weeks", bucketMs: 14 * DAY };
  }
  if (durationMs <= 1825 * DAY) {
    return { bucket: "1 month", bucketMs: MONTH };
  }
  return { bucket: "3 months", bucketMs: 90 * DAY };
}


export const RANGES: Record<RangeKey, RangeSpec> = {
  // New UI presets.
  "7D":  { key: "7D",  label: "7 Days",   spanMs: 7 * DAY,   bucket: "1 day",    bucketMs: DAY },
  "30D": { key: "30D", label: "30 Days",  spanMs: 30 * DAY,  bucket: "1 day",    bucketMs: DAY },
  "90D": { key: "90D", label: "90 Days",  spanMs: 90 * DAY,  bucket: "1 day",    bucketMs: DAY },
  "6M":  { key: "6M",  label: "6 Months", spanMs: 182 * DAY, bucket: "1 week",   bucketMs: WEEK },
  "Y":   { key: "Y",   label: "1 Year",   spanMs: 365 * DAY, bucket: "1 week",   bucketMs: WEEK },
  "2Y":  { key: "2Y",  label: "2 Years",  spanMs: 730 * DAY, bucket: "2 weeks",  bucketMs: 14 * DAY },
  "5Y":  { key: "5Y",  label: "5 Years",  spanMs: 1825 * DAY, bucket: "1 month", bucketMs: MONTH },
  "ALL": { key: "ALL", label: "All Time", spanMs: null,      bucket: "3 months", bucketMs: 90 * DAY },
  "CUSTOM": { key: "CUSTOM", label: "Custom", spanMs: null,   bucket: "1 day",    bucketMs: DAY },

  // Backward-compatible keys used by the existing dashboard/demo code.
  D: { key: "D", label: "Day", spanMs: DAY, bucket: "1 hour", bucketMs: HOUR },
  W: { key: "W", label: "Week", spanMs: 7 * DAY, bucket: "1 day", bucketMs: DAY },
  M: { key: "M", label: "Month", spanMs: 30 * DAY, bucket: "1 day", bucketMs: DAY },
};

export const RANGE_ORDER: RangeKey[] = [
  "7D",
  "30D",
  "90D",
  "6M",
  "Y",
  "2Y",
  "5Y",
  "ALL",
  "CUSTOM",
];

export function parseRange(v: string | null | undefined): RangeKey {
  if (v && (RANGE_ORDER as string[]).includes(v)) return v as RangeKey;

  // Preserve sensible behavior for old bookmarked URLs.
  if (v === "D" || v === "W") return "7D";
  if (v === "M") return "30D";

  return "7D";
}


export interface SeriesWindow {
  range: Exclude<RangeKey, "CUSTOM">;
  start: Date;
  end: Date;
  bucket: string;
  bucketMs: number;
}

export interface CustomSeriesWindow {
  range: "CUSTOM";
  fromDate: string;
  toDate: string;
  endExclusive: string;
  bucket: string;
  bucketMs: number;
}

export type ResolvedSeriesWindow = SeriesWindow | CustomSeriesWindow;

export function resolveCustomWindow(
  fromDate: string,
  toDate: string,
): CustomSeriesWindow {
  const datePattern = /^\d{4}-\d{2}-\d{2}$/;

  const isValidDate = (value: string): boolean => {
    if (!datePattern.test(value)) return false;

    const [year, month, day] = value.split("-").map(Number);
    const date = new Date(Date.UTC(year, month - 1, day));

    return (
      date.getUTCFullYear() === year &&
      date.getUTCMonth() === month - 1 &&
      date.getUTCDate() === day
    );
  };

  if (!isValidDate(fromDate) || !isValidDate(toDate)) {
    throw new Error("Invalid custom date range");
  }

  const from = new Date(`${fromDate}T00:00:00Z`);
  const to = new Date(`${toDate}T00:00:00Z`);
  const durationMs = to.getTime() - from.getTime() + DAY;

  if (!Number.isFinite(durationMs) || durationMs < DAY) {
    throw new Error("Invalid custom date range");
  }

  const { bucket, bucketMs } = bucketForDuration(durationMs);

  return {
    range: "CUSTOM",
    fromDate,
    toDate,
    endExclusive: new Date(to.getTime() + DAY).toISOString().slice(0, 10),
    bucket,
    bucketMs,
  };
}

export function resolvePresetWindow(
  range: Exclude<RangeKey, "CUSTOM">,
  now = new Date(),
  earliestMs?: number | null,
): SeriesWindow {
  const spec = RANGES[range];

  const end = now;
  const start =
    range === "ALL" && earliestMs != null
      ? new Date(earliestMs)
      : new Date(end.getTime() - (spec.spanMs ?? 5 * 365 * DAY));

  return {
    range,
    start,
    end,
    bucket: spec.bucket,
    bucketMs: spec.bucketMs,
  };
}
