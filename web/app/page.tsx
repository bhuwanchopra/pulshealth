import Link from "next/link";
import { ActivityRings, type RingDatum } from "@/components/ActivityRings";
import { Distance } from "@/components/Distance";
import { MetricCard } from "@/components/MetricCard";
import { SleepCard } from "@/components/SleepCard";
import { PageHeader } from "@/components/PageHeader";
import { GroupIcon, ChevronRight } from "@/components/Icons";
import { GROUPS, GROUP_LABELS, typeByIdentifier, typesInGroup } from "@/lib/catalog";
import { formatActivity } from "@/lib/activity";
import { GROUP_COLOR } from "@/lib/colors";
import { isCumulative } from "@/lib/metrics";
import { getActivityRings, getLatestMany, getSeries, getSleepDays, getStats, getTodayTotals, getWorkouts } from "@/lib/queries";
import { viewerUser } from "@/lib/viewer";
import { formatCompact, formatDuration, formatFull, formatToday } from "@/lib/format";
import { greetingAt } from "@/lib/time";

// Always render live from the DB — no build-time demo snapshot, no stale cache.
export const dynamic = "force-dynamic";

const KEY_METRICS = [
  "HKQuantityTypeIdentifierStepCount",
  "HKQuantityTypeIdentifierActiveEnergyBurned",
  "HKQuantityTypeIdentifierRestingHeartRate",
  "HKCategoryTypeIdentifierSleepAnalysis",
  "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
  "HKQuantityTypeIdentifierDistanceWalkingRunning",
  "HKQuantityTypeIdentifierVO2Max",
  "HKQuantityTypeIdentifierBodyMass",
];

// Fallback rings when no HKActivitySummary row exists yet: derived from today's
// quantity totals with hardcoded goals (Move / Exercise / Steps).
const RING_TYPES = [
  "HKQuantityTypeIdentifierActiveEnergyBurned",
  "HKQuantityTypeIdentifierAppleExerciseTime",
  "HKQuantityTypeIdentifierStepCount",
];

export default async function Dashboard() {
  const now = new Date();
  const user = await viewerUser();
  const [latest, todays, stats, workouts, activity, sleepDays] = await Promise.all([
    getLatestMany(user, KEY_METRICS.filter((id) => !isCumulative(id))),
    getTodayTotals(user, [...new Set([...RING_TYPES, ...KEY_METRICS.filter(isCumulative)])]),
    getStats(user),
    getWorkouts(user, 3),
    getActivityRings(user),
    getSleepDays(user, 14),
  ]);

  const seriesList = await Promise.all(KEY_METRICS.map((id) => getSeries(user, id, "M")));
  const seriesById = new Map(seriesList.map((s) => [s.identifier, s]));

  // Rings: prefer the real HKActivitySummary (Move / Exercise / Stand with the
  // user's own goals). When no summary has synced yet, fall back to today's
  // quantity totals with hardcoded goals (Move / Exercise / Steps).
  const MOVE_COLOR = "#ff453a";
  const EXERCISE_COLOR = "#30d158";
  const STAND_COLOR = "#64d2ff";
  let rings: RingDatum[];
  if (activity.hasData) {
    const move: RingDatum = activity.moveMode === 1
      ? { label: "Move", value: Math.round(activity.moveTimeMin ?? 0), goal: Math.round(activity.moveTimeGoalMin ?? 30), unit: "min", color: MOVE_COLOR }
      : { label: "Move", value: Math.round(activity.moveKcal), goal: Math.round(activity.moveGoalKcal), unit: "Cal", color: MOVE_COLOR };
    rings = [
      move,
      { label: "Exercise", value: Math.round(activity.exerciseMin), goal: Math.round(activity.exerciseGoalMin), unit: "min", color: EXERCISE_COLOR },
      { label: "Stand", value: Math.round(activity.standHours), goal: Math.round(activity.standGoalHours), unit: "hrs", color: STAND_COLOR },
    ];
  } else {
    const ringGoals: Record<string, { goal: number; unit: string; color: string; label: string }> = {
      HKQuantityTypeIdentifierActiveEnergyBurned: { goal: 600, unit: "Cal", color: MOVE_COLOR, label: "Move" },
      HKQuantityTypeIdentifierAppleExerciseTime: { goal: 30, unit: "min", color: EXERCISE_COLOR, label: "Exercise" },
      HKQuantityTypeIdentifierStepCount: { goal: 10000, unit: "steps", color: STAND_COLOR, label: "Steps" },
    };
    rings = RING_TYPES.map((id) => {
      const g = ringGoals[id];
      return { label: g.label, value: Math.round(todays.get(id) ?? 0), goal: g.goal, unit: g.unit, color: g.color };
    });
  }

  return (
    <>
      <PageHeader
        eyebrow={`Today · ${formatToday(now)}`}
        title={greetingAt(now)}
        subtitle="Your health data, synced from Apple Health to your own server — and finally easy to look at."
      />

      {/* Hero: rings + headline numbers */}
      <section className="panel rise" style={{ padding: 28, marginBottom: 22, animationDelay: "40ms" }}>
        <div style={{ display: "flex", gap: 34, alignItems: "center", flexWrap: "wrap" }}>
          <div style={{ position: "relative", flex: "none" }}>
            <ActivityRings rings={rings} />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 22, flex: 1, minWidth: 240 }}>
            {rings.map((r) => (
              <div key={r.label}>
                <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
                  <span className="dot" style={{ background: r.color }} />
                  <span className="eyebrow" style={{ color: "var(--muted)" }}>{r.label}</span>
                </div>
                <div className="metric-num" style={{ fontSize: 34, fontWeight: 600, marginTop: 8 }}>
                  {formatCompact(r.value)}
                  <span style={{ fontSize: 14, color: "var(--muted)", fontWeight: 400 }}> / {formatCompact(r.goal)}</span>
                </div>
                <div style={{ fontSize: 12, color: "var(--faint)", marginTop: 3 }}>{r.unit}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Highlights */}
      <h2 className="eyebrow" style={{ margin: "30px 0 14px" }}>Highlights</h2>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(232px, 1fr))", gap: 14 }}>
        {KEY_METRICS.map((id) => {
          const type = typeByIdentifier(id);
          if (!type) return null;
          if (id === "HKCategoryTypeIdentifierSleepAnalysis") {
            return (
              <div key={id} className="rise" style={{ animationDelay: "80ms" }}>
                <SleepCard sleep={sleepDays[0] ?? null} compact />
              </div>
            );
          }
          const s = seriesById.get(id);
          const spark = (s?.points ?? []).slice(-14).map((p) => p.value);
          const value = isCumulative(id)
            ? todays.get(id) ?? null
            : latest.get(id)?.value ?? s?.points.at(-1)?.value ?? null;
          return (
            <div key={id} className="rise" style={{ animationDelay: "80ms" }}>
              <MetricCard type={type} value={value} unit={type.unit} spark={spark} t={latest.get(id)?.t} />
            </div>
          );
        })}
      </div>

      {/* Recent workouts */}
      {workouts.length > 0 && (
        <>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", margin: "34px 0 14px" }}>
            <h2 className="eyebrow" style={{ margin: 0 }}>Recent workouts</h2>
            <Link href="/workouts" style={{ fontSize: 13, color: "var(--muted)", display: "inline-flex", alignItems: "center", gap: 2 }}>
              All workouts <ChevronRight size={14} />
            </Link>
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(240px, 1fr))", gap: 14 }}>
            {workouts.map((w) => (
              <Link key={w.uuid} href={`/workouts/${encodeURIComponent(w.uuid)}`} className="card" style={{ padding: 18 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="dot" style={{ background: GROUP_COLOR.workouts }} />
                  <span style={{ fontWeight: 550 }}>{formatActivity(w.activityType)}</span>
                </div>
                <div className="metric-num" style={{ fontSize: 26, fontWeight: 600, marginTop: 12 }}>{formatDuration(w.durationS)}</div>
                <div style={{ display: "flex", gap: 14, marginTop: 10, color: "var(--muted)", fontSize: 12.5 }} className="mono">
                  {w.energyKcal != null && <span>{formatCompact(w.energyKcal)} Cal</span>}
                  {w.distanceM != null && <span><Distance meters={w.distanceM} /></span>}
                </div>
                <div style={{ fontSize: 11, color: "var(--faint)", marginTop: 8 }}>{formatFull(w.start)}</div>
              </Link>
            ))}
          </div>
        </>
      )}

      {/* Browse categories */}
      <h2 className="eyebrow" style={{ margin: "34px 0 14px" }}>Browse</h2>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(186px, 1fr))", gap: 14 }}>
        {GROUPS.map((g) => {
          const types = typesInGroup(g);
          const totalRows = types.reduce((sum, t) => sum + (stats.get(t.identifier)?.rows ?? 0), 0);
          return (
            <Link key={g} href={g === "workouts" ? "/workouts" : `/category/${g}`} className="card" style={{ padding: 18 }}>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                <span
                  style={{ width: 38, height: 38, borderRadius: 11, display: "grid", placeItems: "center", background: `${GROUP_COLOR[g]}1a`, color: GROUP_COLOR[g] }}
                >
                  <GroupIcon group={g} size={20} />
                </span>
                <ChevronRight size={16} className="muted" />
              </div>
              <div style={{ fontWeight: 550, marginTop: 14 }}>{GROUP_LABELS[g]}</div>
              <div className="mono" style={{ fontSize: 12, color: "var(--faint)", marginTop: 3 }}>
                {types.length} types · {formatCompact(totalRows)} samples
              </div>
            </Link>
          );
        })}
      </div>
    </>
  );
}
