import { PageHeader } from "@/components/PageHeader";
import { SleepCard } from "@/components/SleepCard";
import { SleepHistoryChart } from "@/components/SleepHistoryChart";
import { SleepRangeSelector, parseSleepRange, sleepRangeDays } from "@/components/SleepRangeSelector";
import { getSleepDays } from "@/lib/queries";
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
  const nights = await getSleepDays(user, sleepRangeDays(range));

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
          <SleepCard sleep={nights[0]} />
          <SleepHistoryChart nights={nights} />
        </div>
      )}
    </>
  );
}
