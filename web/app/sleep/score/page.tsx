import Link from "next/link";
import { notFound } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { SleepRangeSelector } from "@/components/SleepRangeSelector";
import { SleepScoreHistoryChart } from "@/components/SleepScoreHistoryChart";
import { ChevronRight } from "@/components/Icons";
import { GROUP_COLOR } from "@/lib/colors";
import {
  getOrCreateSleepScores,
  getSleepDays,
} from "@/lib/queries";
import {
  parseSleepRange,
  sleepRangeBucket,
  sleepRangeDays,
  sleepScoreClassification,
} from "@/lib/sleep";
import { viewerUser } from "@/lib/viewer";

export const dynamic = "force-dynamic";

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="panel panel-tight" style={{ padding: "14px 16px" }}>
      <div className="eyebrow" style={{ fontSize: 10 }}>{label}</div>
      <div className="metric-num tabular" style={{ fontSize: 22, fontWeight: 600, marginTop: 8 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: "var(--faint)", marginTop: 3 }}>{sub}</div>}
    </div>
  );
}

function formatMinutes(minutes: number | null): string {
  if (minutes == null) return "—";
  const sign = minutes < 0 ? "−" : "";
  const absolute = Math.abs(minutes);
  const hours = Math.floor(absolute / 60);
  const mins = absolute % 60;
  return hours ? `${sign}${hours}h ${mins}m` : `${sign}${mins}m`;
}

export default async function SleepScorePage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string }>;
}) {
  const query = await searchParams;
  const range = parseSleepRange(query.range);
  const rangeDays = sleepRangeDays(range);
  const scoreWindowDays = rangeDays === 0 ? 0 : rangeDays + 13;
  const user = await viewerUser();

  const [scoreWindowNights, visibleNights] = await Promise.all([
    getSleepDays(user, scoreWindowDays),
    getSleepDays(user, rangeDays),
  ]);

  const scoredWindow = await getOrCreateSleepScores(
    user,
    scoreWindowNights,
    visibleNights.map((night) => night.date),
  );
  const visibleDates = new Set(visibleNights.map((night) => night.date));
  const scores = scoredWindow.filter((entry) => visibleDates.has(entry.night.date));

  // The score list is chronological, while the sleep category page keeps its
  // latest night first. The detail page uses the chronological list for the
  // history chart but explicitly selects the newest entry for the headline.
  const latestScore = scores.at(-1) ?? null;
  const values = scores.map((entry) => entry.score.score).filter(Number.isFinite);
  const avg = values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
  const min = values.length ? Math.min(...values) : null;
  const max = values.length ? Math.max(...values) : null;

  if (!scores.length && !visibleNights.length) {
    notFound();
  }

  const color = GROUP_COLOR.sleep;
  const interval = sleepRangeBucket(range).interval;
  const score = latestScore?.score ?? null;

  return (
    <>
      <nav
        style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: "var(--muted)", marginBottom: 22 }}
        className="rise"
      >
        <Link href="/category/sleep" style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          Sleep
        </Link>
        <ChevronRight size={14} />
        <span style={{ color: "var(--fg-soft)" }}>Sleep Score</span>
      </nav>

      <PageHeader
        eyebrow="Sleep"
        accent={color}
        title="Sleep Score"
        subtitle="A derived 0–100 score combining sleep duration, bedtime consistency, and overnight interruptions."
        right={<SleepRangeSelector value={range} />}
      />

      <section className="panel rise" style={{ padding: "26px 28px", marginBottom: 18, animationDelay: "40ms" }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 14, flexWrap: "wrap" }}>
          <div>
            <div className="eyebrow" style={{ marginBottom: 8 }}>Latest</div>
            <div className="metric-num" style={{ fontSize: "clamp(40px, 8vw, 64px)", fontWeight: 600 }}>
              {score == null ? "—" : score.score}
              {score && <span style={{ fontSize: 20, color: "var(--muted)", fontWeight: 400, marginLeft: 8 }}>/ 100</span>}
            </div>
            {score && (
              <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 5 }}>
                {sleepScoreClassification(score.score)}
              </div>
            )}
          </div>
          {latestScore && (
            <div style={{ marginLeft: "auto", textAlign: "right", color: "var(--muted)", fontSize: 13 }}>
              <div>{latestScore.night.date}</div>
              <div style={{ marginTop: 3 }}>
                {score?.baselineNights ?? 0} prior nights used for consistency
              </div>
            </div>
          )}
        </div>

        {score && (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", gap: 12, marginTop: 24 }}>
            <Stat label="Duration" value={`${Math.round(score.durationPoints)}/50`} />
            <Stat label="Consistency" value={`${Math.round(score.consistencyPoints)}/30`} sub={formatMinutes(score.bedtimeDeviationMinutes) + " from baseline"} />
            <Stat label="Interruptions" value={`${Math.round(score.interruptionPoints)}/20`} sub={`${score.awakePeriods} awake periods · ${score.awakeMinutes}m awake`} />
          </div>
        )}
      </section>

      <div className="rise" style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 12, animationDelay: "80ms" }}>
        <Stat label="Average" value={avg == null ? "—" : avg.toFixed(1)} sub={range} />
        <Stat label="Minimum" value={min == null ? "—" : String(min)} />
        <Stat label="Maximum" value={max == null ? "—" : String(max)} />
        <Stat label="Scored nights" value={String(values.length)} />
      </div>

      <div style={{ marginTop: 18 }}>
        <SleepScoreHistoryChart scores={scores} interval={interval} />
      </div>
    </>
  );
}
