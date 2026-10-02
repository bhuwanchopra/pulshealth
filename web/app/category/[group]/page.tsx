import type { ReactNode } from "react";
import { notFound, redirect } from "next/navigation";
import { MetricCard } from "@/components/MetricCard";
import { PageHeader } from "@/components/PageHeader";
import { GroupIcon } from "@/components/Icons";
import { SleepScoreHistoryChart } from "@/components/SleepScoreHistoryChart";
import { SleepScoreCard } from "@/components/SleepScoreCard";
import { SleepRangeSelector } from "@/components/SleepRangeSelector";
import { GROUP_LABELS, GROUPS, type Group, typesInGroup } from "@/lib/catalog";
import { GROUP_COLOR } from "@/lib/colors";
import { isCumulative } from "@/lib/metrics";
import { getDailySparklines, getLatestMany, getOrCreateSleepScores, getSeries, getSleepDays, getStats, getTodayTotals } from "@/lib/queries";
import { parseSleepRange, sleepRangeBucket, sleepRangeDays } from "@/lib/sleep";
import { viewerUser } from "@/lib/viewer";
import { formatCompact } from "@/lib/format";

// Always render live from the DB — no build-time demo snapshot, no stale cache.
export const dynamic = "force-dynamic";

const GROUP_BLURB: Record<Group, string> = {
  activity: "Movement, energy, distance, and exercise across your day.",
  heart: "Heart rate, variability, and cardiovascular signals.",
  body: "Weight, composition, and body measurements over time.",
  respiratory: "Breathing rate and blood oxygen saturation.",
  sleep: "Time asleep, stages, and overnight recovery signals.",
  nutrition: "Energy, macros, hydration, and what you consume.",
  vitals: "Blood pressure, glucose, temperature, and key vitals.",
  workouts: "Logged training sessions with energy and distance.",
  other: "State of mind, audio exposure, mindfulness, and more.",
};

export async function generateMetadata({ params }: { params: Promise<{ group: string }> }) {
  const { group } = await params;
  const g = group as Group;
  return { title: GROUP_LABELS[g] ? `${GROUP_LABELS[g]} — PulsHealth` : "PulsHealth" };
}

export default async function CategoryPage({
  params,
  searchParams,
}: {
  params: Promise<{ group: string }>;
  searchParams: Promise<{ range?: string }>;
}) {
  const { group } = await params;
  if (!(GROUPS as string[]).includes(group)) notFound();

  const g = group as Group;
  if (g === "workouts") redirect("/workouts");
  const types = typesInGroup(g);
  const color = GROUP_COLOR[g];

  const quantityIds = types.filter((t) => t.kind === "quantity").map((t) => t.identifier);
  const cumIds = quantityIds.filter(isCumulative);
  const discIds = quantityIds.filter((id) => !isCumulative(id));
  const otherTypes = types.filter((t) => t.kind !== "quantity");

  const user = await viewerUser();
  const [sparks, todays, latest, stats, otherSeries] = await Promise.all([
    getDailySparklines(user, quantityIds),
    getTodayTotals(user, cumIds),
    getLatestMany(user, discIds),
    getStats(user),
    Promise.all(otherTypes.map((t) => getSeries(user, t.identifier, "M"))),
  ]);
  const otherById = new Map(otherSeries.map((s) => [s.identifier, s]));

  const ordered = [...types].sort((a, b) => (stats.get(b.identifier)?.rows ?? 0) - (stats.get(a.identifier)?.rows ?? 0));
  const totalRows = types.reduce((s, t) => s + (stats.get(t.identifier)?.rows ?? 0), 0);

  const renderMetricGrid = (extra?: ReactNode) => (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(232px, 1fr))", gap: 14 }}>
      {ordered.map((type, i) => {
        const id = type.identifier;
        let value: number | null;
        let spark: number[];
        let unit = type.unit;
        let t: number | null | undefined;

        if (type.kind === "quantity") {
          spark = sparks.get(id) ?? [];
          value = isCumulative(id) ? todays.get(id) ?? null : latest.get(id)?.value ?? spark.at(-1) ?? null;
          t = latest.get(id)?.t;
        } else {
          const s = otherById.get(id);
          spark = (s?.points ?? []).slice(-14).map((p) => p.value);
          value = s?.points.at(-1)?.value ?? null;
          unit = s?.unit ?? type.unit;
        }

        return (
          <div key={id} className="rise" style={{ animationDelay: `${Math.min(i, 16) * 28}ms` }}>
            <MetricCard type={type} value={value} unit={unit} spark={spark} t={t} />
          </div>
        );
      })}
      {extra}
    </div>
  );

  const pageHeader = (
    <PageHeader
      eyebrow="Category"
      accent={color}
      title={
        <span style={{ display: "inline-flex", alignItems: "center", gap: 14 }}>
          <span style={{ width: 44, height: 44, borderRadius: 13, display: "grid", placeItems: "center", background: `${color}1a`, color }}>
            <GroupIcon group={g} size={24} />
          </span>
          {GROUP_LABELS[g]}
        </span>
      }
      subtitle={GROUP_BLURB[g]}
      right={
        <div className="chip">
          <span className="dot" style={{ background: color }} />
          {types.length} types · {formatCompact(totalRows)} samples
        </div>
      }
    />
  );

  if (g === "sleep") {
    const params = await searchParams;
    const range = parseSleepRange(params.range);
    const rangeDays = sleepRangeDays(range);
    const scoreWindowDays = rangeDays === 0 ? 0 : rangeDays + 13;
    const [scoreWindowNights, rawNights] = await Promise.all([
      getSleepDays(user, scoreWindowDays),
      getSleepDays(user, rangeDays),
    ]);
    const scoredWindow = await getOrCreateSleepScores(
      user,
      scoreWindowNights,
      rawNights.map((night) => night.date),
    );
    const visibleDates = new Set(rawNights.map((night) => night.date));
    const historicalScores = scoredWindow.filter((entry) => visibleDates.has(entry.night.date));
    const latestSleep = historicalScores[0];
    return (
      <>
        {pageHeader}
        {renderMetricGrid(<SleepScoreCard score={latestSleep?.score ?? null} history={historicalScores} />)}
        <div style={{ display: "grid", gap: 14, marginTop: 14 }}>
          <div style={{ display: "flex", justifyContent: "flex-end" }}>
            <SleepRangeSelector value={range} />
          </div>
          <SleepScoreHistoryChart scores={historicalScores} interval={sleepRangeBucket(range).interval} />
        </div>
      </>
    );
  }

  return (
    <>
      {pageHeader}
      {renderMetricGrid()}
    </>
  );
}
