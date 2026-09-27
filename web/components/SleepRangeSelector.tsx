"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";

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

export function parseSleepRange(value: string | null | undefined): SleepRangeKey {
  return SLEEP_RANGES.some((range) => range.key === value)
    ? (value as SleepRangeKey)
    : "7D";
}

export function SleepRangeSelector({ value }: { value: SleepRangeKey }) {
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();

  function select(key: SleepRangeKey) {
    const next = new URLSearchParams(params.toString());
    next.set("range", key);
    router.replace(`${pathname}?${next.toString()}`, { scroll: false });
  }

  return (
    <div className="segmented" role="group" aria-label="Sleep history time range">
      {SLEEP_RANGES.map((range) => (
        <button
          key={range.key}
          type="button"
          aria-pressed={value === range.key}
          data-active={value === range.key}
          onClick={() => select(range.key)}
        >
          {range.label}
        </button>
      ))}
    </div>
  );
}
