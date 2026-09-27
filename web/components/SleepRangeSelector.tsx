"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { SLEEP_RANGES, type SleepRangeKey } from "@/lib/sleep";

export { SLEEP_RANGES };
export type { SleepRangeKey };

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
