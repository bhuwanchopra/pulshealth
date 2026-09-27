export interface SleepDay {
  date: string;
  asleepMinutes: number;
  inBedMinutes: number;
  coreMinutes: number;
  deepMinutes: number;
  remMinutes: number;
  unspecifiedMinutes: number;
  awakeMinutes: number;
  /** Number of nights represented by this bucket (1 for a daily bucket). */
  nights?: number;
}

export const SLEEP_RANGES = [
  { key: "7D", label: "7D", days: 7 },
  { key: "30D", label: "30D", days: 30 },
  { key: "90D", label: "90D", days: 90 },
  { key: "6M", label: "6M", days: 182 },
  { key: "1Y", label: "1Y", days: 365 },
  { key: "2Y", label: "2Y", days: 730 },
  { key: "5Y", label: "5Y", days: 1825 },
  { key: "ALL", label: "ALL", days: 0 },
] as const;

export type SleepRangeKey = (typeof SLEEP_RANGES)[number]["key"];

export function sleepRangeDays(key: SleepRangeKey): number {
  return SLEEP_RANGES.find((range) => range.key === key)?.days ?? 7;
}

export function sleepRangeBucket(key: SleepRangeKey): { interval: string; bucketMs: number } {
  switch (key) {
    case "2Y":
      return { interval: "14 days", bucketMs: 14 * 86_400_000 };
    case "5Y":
      return { interval: "1 month", bucketMs: 30 * 86_400_000 };
    case "ALL":
      return { interval: "3 months", bucketMs: 90 * 86_400_000 };
    default:
      return { interval: "1 day", bucketMs: 86_400_000 };
  }
}

export function parseSleepRange(value: string | null | undefined): SleepRangeKey {
  return SLEEP_RANGES.some((range) => range.key === value)
    ? (value as SleepRangeKey)
    : "7D";
}
