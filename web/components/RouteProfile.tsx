// SVG profile of the route plotted against cumulative distance. Values follow
// the selected workout unit system. No interactivity; the map is the interactive
// piece. Built on the same chart helpers as TrendChart.

import { makeScale, niceTicks, smoothPath, type Pt } from "@/lib/chart";
import type { ProfilePoint } from "@/lib/geo";
import {
  distanceUnit,
  distanceValue,
  elevationUnit,
  elevationValue,
  speedUnit,
  speedValue,
  type UnitSystem,
} from "@/lib/units";

const PAD = { top: 14, right: 14, bottom: 24, left: 44 };
const W = 760;

export function RouteProfile({
  points,
  metric,
  color,
  system,
  height = 170,
}: {
  points: ProfilePoint[];
  metric: "altitude" | "speed";
  color: string;
  system: UnitSystem;
  height?: number;
}) {
  const xy = points
    .map((p) => {
      const y = metric === "altitude"
        ? (p.altitude == null ? null : elevationValue(p.altitude, system))
        : (p.speed == null ? null : speedValue(p.speed, system));
      return { x: distanceValue(p.distM, system), y };
    })
    .filter((d): d is { x: number; y: number } => d.y != null && Number.isFinite(d.y));

  if (xy.length < 2) return null;

  const innerW = W - PAD.left - PAD.right;
  const innerH = height - PAD.top - PAD.bottom;

  const xs = xy.map((d) => d.x);
  const ys = xy.map((d) => d.y);
  const xMax = Math.max(...xs);
  const minY = Math.min(...ys);
  const { lo, hi, ticks } = niceTicks(metric === "speed" ? Math.min(minY, 0) : minY, Math.max(...ys));

  const sx = makeScale(0, xMax || 1, PAD.left, PAD.left + innerW);
  const sy = makeScale(lo, hi, PAD.top + innerH, PAD.top);

  const linePts: Pt[] = xy.map((d) => [sx(d.x), sy(d.y)]);
  const base = sy(lo);
  const areaPath = `${smoothPath(linePts, 0.55)} L ${linePts[linePts.length - 1][0]} ${base} L ${linePts[0][0]} ${base} Z`;

  const grid = ticks.map((t) => ({ y: sy(t.val), label: t.label }));

  const xticks = 5;
  const xlabels = Array.from({ length: xticks + 1 }, (_, i) => {
    const distance = (xMax * i) / xticks;
    return { x: sx(distance), distance };
  });

  const gid = `rp-${metric}`;
  const unit = metric === "altitude" ? elevationUnit(system) : speedUnit(system);

  return (
    <svg
      width="100%"
      height={height}
      viewBox={`0 0 ${W} ${height}`}
      preserveAspectRatio="none"
      role="img"
      aria-label={`${metric === "altitude" ? "Elevation" : "Speed"} by ${distanceUnit(system)}`}
      style={{ display: "block" }}
    >
      <defs>
        <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity={0.26} />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>

      {grid.map((g, i) => (
        <g key={i}>
          <line x1={PAD.left} y1={g.y} x2={W - PAD.right} y2={g.y} stroke="var(--border)" strokeOpacity={0.6} />
          <text x={PAD.left - 8} y={g.y + 3} textAnchor="end" fontSize="10.5" fill="var(--faint)" className="mono">
            {g.label}
          </text>
        </g>
      ))}

      {xlabels.map((d, i) => (
        <text key={i} x={d.x} y={height - 7} textAnchor={i === xlabels.length - 1 ? "end" : "middle"} fontSize="10.5" fill="var(--faint)" className="mono">
          {d.distance.toFixed(1)}{i === xlabels.length - 1 ? ` ${distanceUnit(system)}` : ""}
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
