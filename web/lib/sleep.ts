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
  /** Local minutes after midnight when the first asleep sample began. */
  bedtimeMinutes: number | null;
  /** Number of distinct awake intervals recorded for the night. */
  awakePeriods: number;
}

export interface SleepScore {
  score: number;
  durationPoints: number;
  consistencyPoints: number;
  interruptionPoints: number;
  bedtimeDeviationMinutes: number | null;
  baselineNights: number;
  awakeMinutes: number;
  awakePeriods: number;
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
    case "1Y":
      return { interval: "7 days", bucketMs: 7 * 86_400_000 };
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

export function formatSleepPeriodLabel(date: string, interval: string): string {
  const parsed = new Date(`${date}T12:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return date;

  const monthYear = new Intl.DateTimeFormat("en-US", {
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  });
  const monthDayYear = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
  const monthDay = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });

  if (interval === "1 month") return monthYear.format(parsed);

  if (interval === "3 months") {
    const year = parsed.getUTCFullYear();
    const month = parsed.getUTCMonth();
    const end = new Date(Date.UTC(year, month + 3, 0));
    return `${monthDay.format(parsed)}–${monthDay.format(end)}, ${year}`;
  }

  if (interval === "7 days" || interval === "14 days") {
    const days = interval === "7 days" ? 7 : 14;
    const end = new Date(parsed.getTime() + (days - 1) * 86_400_000);
    return `${monthDay.format(parsed)}–${monthDay.format(end)}, ${end.getUTCFullYear()}`;
  }

  return monthDayYear.format(parsed);
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

/**
 * Calculate a Puls Sleep Score using the same three component weights Apple
 * documents for its watchOS 26 score: duration (50), bedtime consistency (30),
 * and interruptions (20). Apple does not publish the exact scoring equations
 * or expose the score through HealthKit, so this is intentionally a derived
 * score and should not be presented as Apple's score.
 *
 * Bedtime consistency uses the previous 13 available nights, matching Apple's
 * documented look-back window. Bedtime is compared circularly because 23:50
 * and 00:10 are only 20 minutes apart.
 */
export function calculateSleepScore(night: SleepDay, recentNights: SleepDay[]): SleepScore {
  const duration = night.asleepMinutes;
  let durationPoints: number;
  if (duration <= 240) durationPoints = 0;
  else if (duration < 480) durationPoints = ((duration - 240) / 240) * 50;
  else if (duration <= 540) durationPoints = 50;
  else durationPoints = clamp(50 - ((duration - 540) / 180) * 50, 0, 50);

  const baseline = recentNights
    .filter((day) => day.bedtimeMinutes != null)
    .slice(0, 13);
  let bedtimeDeviationMinutes: number | null = null;
  let consistencyPoints = 0;
  if (night.bedtimeMinutes != null && baseline.length > 0) {
    const sorted = baseline.map((day) => day.bedtimeMinutes as number).sort((a, b) => a - b);
    const median = sorted[Math.floor(sorted.length / 2)];
    const direct = Math.abs(night.bedtimeMinutes - median);
    bedtimeDeviationMinutes = Math.min(direct, 1440 - direct);
    consistencyPoints = 30 * clamp(1 - bedtimeDeviationMinutes / 120, 0, 1);
  } else if (night.bedtimeMinutes != null) {
    consistencyPoints = 30;
  }

  const inBed = Math.max(night.inBedMinutes, night.asleepMinutes);
  const awakeFraction = inBed > 0 ? night.awakeMinutes / inBed : 1;
  const awakeDurationPoints = 10 * clamp(1 - awakeFraction / 0.20, 0, 1);
  const awakeCountPoints = 10 * clamp(1 - Math.max(0, night.awakePeriods - 1) / 5, 0, 1);
  const interruptionPoints = awakeDurationPoints + awakeCountPoints;

  return {
    score: Math.round(clamp(durationPoints + consistencyPoints + interruptionPoints, 0, 100)),
    durationPoints: Math.round(durationPoints * 10) / 10,
    consistencyPoints: Math.round(consistencyPoints * 10) / 10,
    interruptionPoints: Math.round(interruptionPoints * 10) / 10,
    bedtimeDeviationMinutes,
    baselineNights: baseline.length,
    awakeMinutes: night.awakeMinutes,
    awakePeriods: night.awakePeriods,
  };
}

export function sleepScoreClassification(score: number): string {
  if (score >= 96) return "Very High";
  if (score >= 81) return "High";
  if (score >= 61) return "OK";
  if (score >= 41) return "Low";
  return "Very Low";
}

export function aggregateSleepDays(days: SleepDay[], interval: string): SleepDay[] {
  if (interval === "1 day") return days.map((day) => ({ ...day, nights: day.nights ?? 1 }));

  const groups = new Map<string, SleepDay & { _count: number }>();
  const bucketKey = (date: string): string => {
    const d = new Date(date + "T12:00:00Z");
    if (interval === "7 days" || interval === "14 days") {
      const dayIndex = Math.floor(d.getTime() / 86_400_000);
      return String(Math.floor(dayIndex / (interval === "7 days" ? 7 : 14)) * (interval === "7 days" ? 7 : 14));
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
    current.awakePeriods += day.awakePeriods;
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
      bedtimeMinutes: null,
      awakePeriods: Math.round(day.awakePeriods / _count),
    }))
    .sort((a, b) => b.date.localeCompare(a.date));
}
