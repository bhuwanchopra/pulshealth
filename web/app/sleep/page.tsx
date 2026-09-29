import { PageHeader } from "@/components/PageHeader";
import { SleepCard } from "@/components/SleepCard";
import { SleepHistoryChart } from "@/components/SleepHistoryChart";
import { SleepScoreHistoryChart } from "@/components/SleepScoreHistoryChart";
import { SleepRangeSelector } from "@/components/SleepRangeSelector";
import { getOrCreateSleepScores, getSleepDays } from "@/lib/queries";
import { aggregateSleepDays, parseSleepRange, sleepRangeBucket, sleepRangeDays } from "@/lib/sleep";
import { viewerUser } from "@/lib/viewer";

export const dynamic = "force-dynamic";

export default async function SleepPage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string }>;
}) {
  const user = await viewerUser();
  const params = await searchParams;
  const range = parseSleepRange(params.range);
  const rangeDays = sleepRangeDays(range);
  // Fetch the selected range plus 13 earlier nights so the first visible
  // night has the complete bedtime-consistency baseline.
  const scoreWindowDays = rangeDays === 0 ? 0 : rangeDays + 13;
  const [scoreWindowNights, rawNights] = await Promise.all([
    getSleepDays(user, scoreWindowDays),
    getSleepDays(user, rangeDays),
  ]);
  const historicalScores = await getOrCreateSleepScores(
    scoreWindowNights,
    rawNights.map((night) => night.date),
  );
  const latest = historicalScores[historicalScores.length - 1];
  const nights = aggregateSleepDays(rawNights, sleepRangeBucket(range).interval);

  return (
    <>
      <PageHeader
        eyebrow="Sleep"
        title="Sleep stages"
        subtitle="SleepAnalysis intervals grouped by wake-up day. Stage durations are kept separate instead of collapsing the night into one number."
        right={<SleepRangeSelector value={range} />}
      />

      {nights.length === 0 ? (
        <div className="panel" style={{ padding: 24 }}>
          <div style={{ fontWeight: 600 }}>No sleep-stage data</div>
          <div style={{ color: "var(--muted)", fontSize: 13, marginTop: 6 }}>
            Sync Sleep Analysis from Apple Health to see Core, Deep, REM, and Awake time.
          </div>
        </div>
      ) : (
        <div style={{ display: "grid", gap: 14 }}>
          <SleepCard sleep={latest?.night ?? null} recentNights={scoreWindowNights} />
          <SleepScoreHistoryChart scores={historicalScores} />
          <SleepHistoryChart nights={nights} interval={sleepRangeBucket(range).interval} />
        </div>
      )}
    </>
  );
}
