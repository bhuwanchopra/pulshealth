import Link from "next/link";
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

  const values = scores.map((entry) => entry.score.score).filter(Number.isFinite);
  const avg = values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;
  const min = values.length ? Math.min(...values) : null;
  const max = values.length ? Math.max(...values) : null;


  const color = GROUP_COLOR.sleep;
  const interval = sleepRangeBucket(range).interval;

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
