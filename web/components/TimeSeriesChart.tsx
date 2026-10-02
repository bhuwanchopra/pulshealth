// Static SVG time-series chart for an intra-workout stream (heart rate, power,
// cadence, speed). X is minutes from the workout start; Y is the metric value.
// Same hand-rolled chart helpers and house style as RouteProfile. Optional
// zone bands (HR zones) shade the background; optional markers draw lap lines.

import { makeScale, niceStep, niceTicks, smoothPath, type Pt } from "@/lib/chart";

const PAD = { top: 14, right: 14, bottom: 24, left: 44 };
const W = 760;

export interface ZoneBand {
  lo: number | null;
  hi: number | null; // null = open-ended (top of chart)
  color: string;
}

export function TimeSeriesChart({
  points,
  startMs,
  color,
  unit,
  height = 170,
  markers = [],
  zoneBands = [],
}: {
  points: { t: number; value: number }[];
  startMs: number;
  color: string;
  unit: string;
  height?: number;
  markers?: number[];
  zoneBands?: ZoneBand[];
}) {
  const xy = points
    .map((p) => ({ x: (p.t - startMs) / 60000, y: p.value })) // minutes, value
    .filter((d) => Number.isFinite(d.x) && Number.isFinite(d.y));
  if (xy.length < 2) return null;

  const innerW = W - PAD.left - PAD.right;
  const innerH = height - PAD.top - PAD.bottom;

  const xs = xy.map((d) => d.x);
  const ys = xy.map((d) => d.y);
  const xMax = Math.max(...xs) || 1;
  const bandVals = zoneBands.flatMap((b) => [b.lo, b.hi].filter((v): v is number => v != null));
  const { lo, hi, ticks } = niceTicks(Math.min(...ys, ...bandVals), Math.max(...ys, ...bandVals));

  const sx = makeScale(0, xMax, PAD.left, PAD.left + innerW);
  const sy = makeScale(lo, hi, PAD.top + innerH, PAD.top);

  const linePts: Pt[] = xy.map((d) => [sx(d.x), sy(d.y)]);
  const base = sy(lo);
  const areaPath = `${smoothPath(linePts, 0.55)} L ${linePts[linePts.length - 1][0]} ${base} L ${linePts[0][0]} ${base} Z`;

  const grid = ticks.map((t) => ({ y: sy(t.val), label: t.label }));

  // Whole multiples of a nice minute step, never past the data's end; the
  // first one carries the unit.
  const xstep = niceStep(xMax / 8);
  const xlabels = Array.from({ length: Math.floor(xMax / xstep.step + 1e-9) + 1 }, (_, i) => {
    const min = i * xstep.step;
    return { x: sx(min), label: i === 0 ? "0 min" : min.toFixed(xstep.decimals) };
  });

  const gid = `ts-${color.replace(/[^a-z0-9]/gi, "")}`;

  return (
    <svg
      width="100%"
      height={height}
      viewBox={`0 0 ${W} ${height}`}
      preserveAspectRatio="none"
      role="img"
      aria-label={`Workout time series in ${unit}`}
      style={{ display: "block" }}
    >
      <defs>
        <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity={0.26} />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>

      {/* Zone bands behind the curve. */}
      {zoneBands.map((b, i) => {
        const top = sy(b.hi == null ? hi : Math.min(b.hi, hi));
        const bot = sy(b.lo == null ? lo : Math.max(b.lo, lo));
        if (bot <= top) return null;
        return <rect key={`b${i}`} x={PAD.left} y={top} width={innerW} height={bot - top} fill={b.color} fillOpacity={0.1} />;
      })}

      {grid.map((g, i) => (
        <g key={i}>
          <line x1={PAD.left} y1={g.y} x2={W - PAD.right} y2={g.y} stroke="var(--border)" strokeOpacity={0.6} />
          <text x={PAD.left - 8} y={g.y + 3} textAnchor="end" fontSize="10.5" fill="var(--faint)" className="mono">
            {g.label}
          </text>
        </g>
      ))}

      {/* Lap / event markers. */}
      {markers.map((m, i) => {
        const x = sx((m - startMs) / 60000);
        if (x < PAD.left || x > W - PAD.right) return null;
        return <line key={`m${i}`} x1={x} y1={PAD.top} x2={x} y2={PAD.top + innerH} stroke="var(--faint)" strokeDasharray="3 3" strokeOpacity={0.55} />;
      })}

      {xlabels.map((d, i) => (
        <text key={i} x={d.x} y={height - 7} textAnchor={i === 0 ? "start" : "middle"} fontSize="10.5" fill="var(--faint)" className="mono">
          {d.label}
        </text>
      ))}
      <text x={W - PAD.right} y={PAD.top - 2} textAnchor="end" fontSize="10" fill="var(--muted)" className="mono">
        {unit}
      </text>

      <path d={areaPath} fill={`url(#${gid})`} />
      <path d={smoothPath(linePts, 0.55)} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
