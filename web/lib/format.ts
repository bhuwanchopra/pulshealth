// Human-friendly formatting for values, units, and times.

import { appTimeZone } from "./time";

// Units that read better than their raw canonical string in a UI.
const UNIT_DISPLAY: Record<string, string> = {
  "count/min": "bpm",
  count: "",
  "kcal": "Cal",
  "m": "m",
  "%": "%",
  "degC": "°C",
  "mmHg": "mmHg",
  "ms": "ms",
  "min": "min",
};

export function displayUnit(unit: string | null | undefined): string {
  if (!unit) return "";
  return UNIT_DISPLAY[unit] ?? unit;
}

export function formatValue(value: number | null | undefined): string {
  if (value == null || Number.isNaN(value)) return "—";
  const abs = Math.abs(value);
  let s: string;
  if (abs >= 100000) s = Math.round(value).toLocaleString();
  else if (abs >= 1000) s = Math.round(value).toLocaleString();
  else if (abs >= 100) s = value.toFixed(0);
  else if (abs >= 10) s = value.toFixed(1);
  else if (abs >= 1) s = value.toFixed(1);
  else if (abs === 0) s = "0";
  else s = value.toFixed(2);
  return s;
}

export function formatCompact(value: number | null | undefined): string {
  if (value == null || Number.isNaN(value)) return "—";
  if (Math.abs(value) >= 1000)
    return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
  return formatValue(value);
}

export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null) return "—";
  const s = Math.round(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return `${s}s`;
}

export function relativeTime(ms: number | null | undefined): string {
  if (ms == null) return "—";
  const diff = Date.now() - ms;
  const sec = Math.round(diff / 1000);
  if (sec < 60) return "just now";
  const min = Math.round(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.round(hr / 24);
  if (day < 30) return `${day}d ago`;
  const mo = Math.round(day / 30);
  if (mo < 12) return `${mo}mo ago`;
  return `${Math.round(mo / 12)}y ago`;
}

function dateFormatter(options: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat(undefined, { ...options, timeZone: appTimeZone() });
}

export function formatDay(ms: number): string {
  return dateFormatter({ month: "short", day: "numeric" }).format(new Date(ms));
}
export function formatTime(ms: number): string {
  return dateFormatter({ hour: "numeric", minute: "2-digit" }).format(new Date(ms));
}
export function formatFull(ms: number): string {
  return dateFormatter({
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(ms));
}

export function formatToday(date = new Date()): string {
  return dateFormatter({ weekday: "long", month: "long", day: "numeric" }).format(date);
}

// The tooltip's timestamp for one chart bucket: an hour bucket names its clock
// time, a day bucket its date, and a longer bucket the span it covers, so a
// weekly total is never mistaken for one day's reading.
export function formatBucket(ms: number, bucketMs: number): string {
  if (bucketMs < 86_400_000) {
    return dateFormatter({ weekday: "short", month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }).format(
      new Date(ms),
    );
  }
  if (bucketMs <= 86_400_000) {
    return dateFormatter({ weekday: "short", month: "short", day: "numeric", year: "numeric" }).format(new Date(ms));
  }
  // A month or quarter bucket (5Y, ALL) is a calendar one on the server, but
  // its bucketMs is a fixed 30 or 90 days, so a day-precise end would be off
  // by up to two days ("Feb 1 – Mar 2"): name the months instead.
  if (bucketMs >= 80 * 86_400_000) {
    return dateFormatter({ month: "short", year: "numeric" }).formatRange(new Date(ms), new Date(ms + bucketMs - 1));
  }
  if (bucketMs >= 28 * 86_400_000) return formatMonth(ms);
  // Inclusive last day of the bucket.
  return dateFormatter({ month: "short", day: "numeric", year: "numeric" }).formatRange(new Date(ms), new Date(ms + bucketMs - 1));
}

// The readout for a zoomed window, [startMs, endMs): one range at the
// chart's grain, so it never reads as two bucket spans joined by a dash.
export function formatWindow(startMs: number, endMs: number, bucketMs: number): string {
  const last = new Date(Math.max(startMs, endMs - 1));
  if (bucketMs < 86_400_000) {
    return dateFormatter({ month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" }).formatRange(new Date(startMs), last);
  }
  if (bucketMs >= 28 * 86_400_000) {
    return dateFormatter({ month: "short", year: "numeric" }).formatRange(new Date(startMs), last);
  }
  return dateFormatter({ month: "short", day: "numeric", year: "numeric" }).formatRange(new Date(startMs), last);
}

export function formatMonth(ms: number): string {
  return dateFormatter({ month: "short", year: "numeric" }).format(new Date(ms));
}

export function tickLabel(ms: number, bucketMs: number): string {
  // Sub-day buckets show the clock; daily and weekly ones the date. Buckets
  // of two weeks or more (2Y, 5Y, All Time) span years, where "Jan 1" alone
  // repeats, so they show the month and year.
  if (bucketMs < 86_400_000) return formatTime(ms);
  if (bucketMs >= 14 * 86_400_000) return formatMonth(ms);
  return formatDay(ms);
}
