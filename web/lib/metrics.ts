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
  /** how far back from now, in ms */
  spanMs: number;
  /** Postgres time_bucket interval literal */
  bucket: string;
  bucketMs: number;
}

const HOUR = 3600_000;
const DAY = 86_400_000;
const WEEK = 7 * DAY;

export const RANGES: Record<RangeKey, RangeSpec> = {
  D: { key: "D", label: "Day", spanMs: DAY, bucket: "1 hour", bucketMs: HOUR },
  W: { key: "W", label: "Week", spanMs: 7 * DAY, bucket: "1 day", bucketMs: DAY },
  M: { key: "M", label: "Month", spanMs: 30 * DAY, bucket: "1 day", bucketMs: DAY },
  // Keep longer ranges at daily grain so client-side zoom can reveal individual days.
  "6M": { key: "6M", label: "6 Months", spanMs: 182 * DAY, bucket: "1 day", bucketMs: DAY },
  Y: { key: "Y", label: "Year", spanMs: 365 * DAY, bucket: "1 day", bucketMs: DAY },
};

export const RANGE_ORDER: RangeKey[] = ["D", "W", "M", "6M", "Y"];

export function parseRange(v: string | null | undefined): RangeKey {
  if (v && (RANGE_ORDER as string[]).includes(v)) return v as RangeKey;
  return "W";
}
