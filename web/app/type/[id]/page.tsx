import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { RangeSelector } from "@/components/RangeSelector";
import { TrendChart } from "@/components/TrendChart";
import { ChevronRight } from "@/components/Icons";
import { GROUP_LABELS, typeByIdentifier } from "@/lib/catalog";
import { GROUP_COLOR } from "@/lib/colors";
import {
  isCumulative,
  parseRange,
  RANGES,
  resolveCustomWindow,
  resolvePresetWindow,
} from "@/lib/metrics";
import { getLatestMany, getSeries, getStats, getTodayTotals } from "@/lib/queries";
import { viewerUser } from "@/lib/viewer";
import { displayUnit, formatCompact, formatFull, formatValue, relativeTime } from "@/lib/format";

// Always render live from the DB — no build-time demo snapshot, no stale cache.
export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }) {
  // Next has already URL-decoded route params; decoding again turned a literal
  // `%` in the path into a URIError (500) instead of a 404.
  const { id } = await params;
  const type = typeByIdentifier(id);
  return { title: type ? `${type.name} — PulsHealth` : "PulsHealth" };
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="panel panel-tight" style={{ padding: "14px 16px" }}>
      <div className="eyebrow" style={{ fontSize: 10 }}>{label}</div>
      <div className="metric-num tabular" style={{ fontSize: 22, fontWeight: 600, marginTop: 8 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: "var(--faint)", marginTop: 3 }}>{sub}</div>}
    </div>
  );
}

export default async function TypePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ range?: string; from?: string; to?: string }>;
}) {
  const { id } = await params;
  const type = typeByIdentifier(id);
  if (!type) notFound();
  if (type.kind === "workout") redirect("/workouts");
  if (type.kind !== "quantity" && type.kind !== "category") notFound();

  const query = await searchParams;
  const range = parseRange(query.range);
  const color = GROUP_COLOR[type.group];
  const cumulative = isCumulative(id);

  const user = await viewerUser();
  const [latestMap, todays, stats] = await Promise.all([
    getLatestMany(user, [id]),
    cumulative ? getTodayTotals(user, [id]) : Promise.resolve(new Map<string, number>()),
    getStats(user),
  ]);

  let seriesWindow;

  if (range === "CUSTOM") {
    if (!query.from || !query.to) {
      redirect(`/type/${encodeURIComponent(id)}?range=7D`);
    }

    try {
      seriesWindow = resolveCustomWindow(query.from, query.to);
    } catch {
      redirect(`/type/${encodeURIComponent(id)}?range=7D`);
    }
  } else {
    seriesWindow = resolvePresetWindow(
      range,
      new Date(),
      range === "ALL" ? stats.get(id)?.earliest : undefined,
    );
  }

  const series = await getSeries(user, id, range, seriesWindow);

  const vals = series.points.map((p) => p.value).filter(Number.isFinite);
  const avg = vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
  // Discrete series carry each bucket's own min/max; the extrema of bucket
  // *averages* understated both (a week's lowest heart rate is not the lowest
  // daily average). Cumulative buckets have no per-bucket extrema, so their
  // totals stand in.
  const mins = series.points.map((p) => p.min ?? p.value).filter(Number.isFinite);
  const maxs = series.points.map((p) => p.max ?? p.value).filter(Number.isFinite);
  const min = mins.length ? Math.min(...mins) : null;
  const max = maxs.length ? Math.max(...maxs) : null;
  const sum = vals.length ? vals.reduce((a, b) => a + b, 0) : null;
  const stat = stats.get(id);
  const latest = latestMap.get(id);

  const unit = series.unit ?? type.unit;
  const headlineValue = cumulative ? todays.get(id) ?? null : latest?.value ?? series.points.at(-1)?.value ?? null;
  const headlineLabel = cumulative ? "Today" : "Latest";

  return (
    <>
      <nav style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: "var(--muted)", marginBottom: 22 }} className="rise">
        <Link href={`/category/${type.group}`} style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          {GROUP_LABELS[type.group]}
        </Link>
        <ChevronRight size={14} />
        <span style={{ color: "var(--fg-soft)" }}>{type.name}</span>
      </nav>

      <PageHeader
        eyebrow={GROUP_LABELS[type.group]}
        accent={color}
        title={type.name}
        subtitle={
          <span className="mono" style={{ fontSize: 12.5 }}>
            {id}
          </span>
        }
        right={<RangeSelector value={range} />}
      />

      {/* Headline */}
      <section className="panel rise" style={{ padding: "26px 28px", marginBottom: 18, animationDelay: "40ms" }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 14, flexWrap: "wrap" }}>
          <div>
            <div className="eyebrow" style={{ marginBottom: 8 }}>{headlineLabel}</div>
            <div className="metric-num" style={{ fontSize: "clamp(40px, 8vw, 64px)", fontWeight: 600 }}>
              {headlineValue == null ? "—" : formatCompact(headlineValue)}
              {unit && <span style={{ fontSize: 20, color: "var(--muted)", fontWeight: 400, marginLeft: 8 }}>{displayUnit(unit)}</span>}
            </div>
          </div>
          {latest && (
            <div style={{ marginLeft: "auto", textAlign: "right", color: "var(--muted)", fontSize: 13 }}>
              <div>Last reading {relativeTime(latest.t)}</div>
              <div className="mono" style={{ fontSize: 12, color: "var(--faint)", marginTop: 2 }}>{formatFull(latest.t)}</div>
            </div>
          )}
        </div>

        <div style={{ marginTop: 22 }}>
          <TrendChart series={series} color={color} />
        </div>
      </section>

      {/* Stats over selected range */}
      <div className="rise" style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 12, animationDelay: "80ms" }}>
        <Stat label={`Average · ${RANGES[range].label}`} value={avg == null ? "—" : `${formatValue(avg)} ${displayUnit(unit)}`} />
        <Stat label="Minimum" value={min == null ? "—" : `${formatValue(min)} ${displayUnit(unit)}`} />
        <Stat label="Maximum" value={max == null ? "—" : `${formatValue(max)} ${displayUnit(unit)}`} />
        {cumulative ? (
          <Stat label={`Total · ${RANGES[range].label}`} value={sum == null ? "—" : `${formatCompact(sum)} ${displayUnit(unit)}`} />
        ) : (
          <Stat label="Buckets" value={`${series.points.length}`} />
        )}
        <Stat
          label="All-time samples"
          value={stat ? formatCompact(stat.rows) : "—"}
          sub={stat?.earliest ? `since ${formatFull(stat.earliest)}` : undefined}
        />
      </div>
    </>
  );
}
