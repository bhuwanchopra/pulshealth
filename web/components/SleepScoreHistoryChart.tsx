import { type SleepDay, type SleepScore } from "@/lib/sleep";
import { TrendChart } from "@/components/TrendChart";

type ScoredNight = { night: SleepDay; score: SleepScore };
function aggregateScores(scores: ScoredNight[], interval: string): ScoredNight[] {
  if (interval === "1 day") return [...scores].sort((a, b) => a.night.date.localeCompare(b.night.date));
  const groups = new Map<string, ScoredNight[]>();
  const keyFor = (date: string) => {
    const d = new Date(date + "T12:00:00Z");
    if (interval === "7 days" || interval === "14 days") {
      const size = interval === "7 days" ? 7 : 14;
      const day = Math.floor(d.getTime() / 86_400_000);
      const bucketDay = Math.floor(day / size) * size;
      return new Date(bucketDay * 86_400_000).toISOString().slice(0, 10);
    }
    const year = d.getUTCFullYear();
    const month = d.getUTCMonth();
    if (interval === "1 month") return `${year}-${String(month + 1).padStart(2, "0")}`;
    return `${year}-${String(Math.floor(month / 3) * 3 + 1).padStart(2, "0")}`;
  };
  for (const score of scores) {
    const key = keyFor(score.night.date);
    groups.set(key, [...(groups.get(key) ?? []), score]);
  }
  return [...groups.entries()].map(([date, group]) => {
    const count = group.length;
    const avg = (pick: (entry: ScoredNight) => number) => group.reduce((sum, entry) => sum + pick(entry), 0) / count;
    const latest = [...group].sort((a, b) => b.night.date.localeCompare(a.night.date))[0];
    const deviations = group.map((entry) => entry.score.bedtimeDeviationMinutes).filter((value): value is number => value != null);
    return {
      night: { ...latest.night, date, nights: count },
      score: {
        score: Math.round(avg((entry) => entry.score.score)),
        durationPoints: Math.round(avg((entry) => entry.score.durationPoints) * 10) / 10,
        consistencyPoints: Math.round(avg((entry) => entry.score.consistencyPoints) * 10) / 10,
        interruptionPoints: Math.round(avg((entry) => entry.score.interruptionPoints) * 10) / 10,
        bedtimeDeviationMinutes: deviations.length ? Math.round(deviations.reduce((sum, value) => sum + value, 0) / deviations.length) : null,
        baselineNights: Math.round(avg((entry) => entry.score.baselineNights)),
        awakeMinutes: Math.round(avg((entry) => entry.score.awakeMinutes)),
        awakePeriods: Math.round(avg((entry) => entry.score.awakePeriods)),
      },
    };
  }).sort((a, b) => a.night.date.localeCompare(b.night.date));
}

const scoreColors = {
  veryLow: "#ef4444",
  low: "#f59e0b",
  ok: "#22c55e",
  high: "#16a34a",
  veryHigh: "#0ea5e9",
} as const;

function scoreColor(score: number): string {
  if (score >= 96) return scoreColors.veryHigh;
  if (score >= 81) return scoreColors.high;
  if (score >= 61) return scoreColors.ok;
  if (score >= 41) return scoreColors.low;
  return scoreColors.veryLow;
}

export function SleepScoreHistoryChart({ scores, interval }: { scores: ScoredNight[]; interval: string }) {
  const points = aggregateScores(scores, interval);
  if (!points.length) return null;

  const bucketMs =
    interval === "7 days" ? 7 * 86_400_000 :
    interval === "14 days" ? 14 * 86_400_000 :
    interval === "1 month" ? 30 * 86_400_000 :
    interval === "3 months" ? 90 * 86_400_000 :
    86_400_000;

  const series = {
    identifier: "PulsHealthSleepScore",
    unit: "score",
    agg: "avg" as const,
    bucketMs,
    points: points.map((point) => {
      const [year, month, day] = point.night.date.split("-").map(Number);
      return {
        t: Date.UTC(year, month - 1, day),
        value: point.score.score,
        min: null,
        max: null,
        count: point.night.nights ?? 1,
      };
    }),
  };

  return (
    <section className="panel" style={{ padding: 20 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 16 }}>
        <div>
          <div className="eyebrow" style={{ color: "var(--muted)" }}>History</div>
          <h2 style={{ margin: "5px 0 0", fontSize: 20 }}>Sleep Score</h2>
          <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 5 }}>
            Derived score for every available night using the preceding 13 nights for bedtime consistency. Longer ranges are aggregated like the sleep-stage history.
          </div>
        </div>
        <div style={{ color: "var(--faint)", fontSize: 12 }}>
          {points.reduce((sum, point) => sum + (point.night.nights ?? 1), 0)} scored nights
        </div>
      </div>

      <div style={{ marginTop: 18 }}>
        <TrendChart series={series} color="#5e5ce6" name="Sleep Score" />
      </div>
    </section>
  );
}
