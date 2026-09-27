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

export function aggregateSleepDays(days: SleepDay[], interval: string): SleepDay[] {
  if (interval === "1 day") return days.map((day) => ({ ...day, nights: day.nights ?? 1 }));

  const groups = new Map<string, SleepDay & { _count: number }>();
  const bucketKey = (date: string): string => {
    const d = new Date(date + "T12:00:00Z");
    if (interval === "14 days") {
      const dayIndex = Math.floor(d.getTime() / 86_400_000);
      return String(Math.floor(dayIndex / 14) * 14);
    }
    const year = d.getUTCFullYear();
    const month = d.getUTCMonth();
    if (interval === "1 month") return `${year}-${String(month + 1).padStart(2, "0")}`;
    return `${year}-${String(Math.floor(month / 3) * 3 + 1).padStart(2, "0")}`;
  };

  for (const day of days) {
    const key = bucketKey(day.date);
    const current = groups.get(key);
    if (!current) {
      groups.set(key, { ...day, nights: 1, _count: 1 });
      continue;
    }
    current.asleepMinutes += day.asleepMinutes;
    current.inBedMinutes += day.inBedMinutes;
    current.coreMinutes += day.coreMinutes;
    current.deepMinutes += day.deepMinutes;
    current.remMinutes += day.remMinutes;
    current.unspecifiedMinutes += day.unspecifiedMinutes;
    current.awakeMinutes += day.awakeMinutes;
    current.nights = (current.nights ?? 0) + 1;
    current._count += 1;
  }

  return [...groups.values()]
    .map(({ _count, ...day }) => ({
      ...day,
      asleepMinutes: day.asleepMinutes / _count,
      inBedMinutes: day.inBedMinutes / _count,
      coreMinutes: day.coreMinutes / _count,
      deepMinutes: day.deepMinutes / _count,
      remMinutes: day.remMinutes / _count,
      unspecifiedMinutes: day.unspecifiedMinutes / _count,
      awakeMinutes: day.awakeMinutes / _count,
    }))
    .sort((a, b) => b.date.localeCompare(a.date));
}
