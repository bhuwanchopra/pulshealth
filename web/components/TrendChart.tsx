"use client";

import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { makeScale, niceBounds, smoothPath, type Pt } from "@/lib/chart";
import { displayUnit, formatValue, tickLabel } from "@/lib/format";

function bucketLabel(timestampMs: number, bucketMs: number): string {
  const start = new Date(timestampMs);

  if (bucketMs <= 24 * 60 * 60 * 1000) {
    return start.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
  }

  if (bucketMs <= 14 * 24 * 60 * 60 * 1000) {
    const end = new Date(timestampMs + bucketMs - 1);

    const startText = start.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
    });

    const endText = end.toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
    });

    return `${startText}–${endText}`;
  }

  if (bucketMs <= 31 * 24 * 60 * 60 * 1000) {
    return start.toLocaleDateString(undefined, {
      month: "long",
      year: "numeric",
    });
  }

  if (bucketMs <= 92 * 24 * 60 * 60 * 1000) {
    const end = new Date(timestampMs + bucketMs - 1);

    const startText = start.toLocaleDateString(undefined, {
      month: "short",
    });

    const endText = end.toLocaleDateString(undefined, {
      month: "short",
      year: "numeric",
    });

    return `${startText}–${endText}`;
  }

  return start.toLocaleDateString(undefined, {
    month: "short",
    year: "numeric",
  });
}
import type { Series } from "@/lib/types";

const PAD = { top: 16, right: 16, bottom: 28, left: 46 };

export function TrendChart({ series, color, height = 300 }: { series: Series; color: string; height?: number }) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [w, setW] = useState(720);
  const [hover, setHover] = useState<number | null>(null);

  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      const cw = entries[0]?.contentRect.width;
      if (cw) setW(Math.max(320, Math.round(cw)));
    });
    ro.observe(el);
    setW(Math.max(320, Math.round(el.getBoundingClientRect().width)));
    return () => ro.disconnect();
  }, []);

  const pts = series.points;
  const isBar = series.agg === "sum";

  const model = useMemo(() => {
    const innerW = w - PAD.left - PAD.right;
    const innerH = height - PAD.top - PAD.bottom;
    if (!pts.length) return null;

    const values = pts.map((p) => p.value).filter(Number.isFinite);
    const mins = pts.map((p) => (p.min ?? p.value)).filter(Number.isFinite);
    const maxs = pts.map((p) => (p.max ?? p.value)).filter(Number.isFinite);
    let lo = Math.min(...mins);
    let hi = Math.max(...maxs, ...values);
    if (isBar) lo = Math.min(0, lo);
    [lo, hi] = niceBounds(lo, hi);

    const n = pts.length;
    const sx = isBar
      ? (i: number) => PAD.left + (innerW * (i + 0.5)) / n
      : makeScale(0, Math.max(1, n - 1), PAD.left, PAD.left + innerW);
    const sy = makeScale(lo, hi, PAD.top + innerH, PAD.top);

    const linePts: Pt[] = pts.map((p, i) => [sx(i), sy(p.value)]);
    const bandTop: Pt[] = pts.map((p, i) => [sx(i), sy(p.max ?? p.value)]);
    const bandBot: Pt[] = pts.map((p, i) => [sx(i), sy(p.min ?? p.value)]);

    // gridlines
    const ticks = 4;
    const grid = Array.from({ length: ticks + 1 }, (_, i) => {
      const val = lo + ((hi - lo) * i) / ticks;
      return { y: sy(val), val };
    });

    // x labels — about 6 evenly spaced
    const labelEvery = Math.max(1, Math.round(n / 6));
    const xlabels = pts
      .map((p, i) => ({ i, x: sx(i), t: p.t }))
      .filter((d) => d.i % labelEvery === 0 || d.i === n - 1);

    const barW = isBar ? Math.max(2, (innerW / n) * 0.62) : 0;

    return { innerW, innerH, sx, sy, lo, hi, linePts, bandTop, bandBot, grid, xlabels, n, barW, base: sy(isBar ? 0 : lo) };
  }, [pts, w, height, isBar]);

  if (!pts.length || !model) {
    return (
      <div ref={wrapRef} style={{ height, display: "grid", placeItems: "center" }}>
        <span className="muted" style={{ color: "var(--muted)", fontSize: 14 }}>No data in this range.</span>
      </div>
    );
  }

  const { sx, sy, linePts, bandTop, bandBot, grid, xlabels, n, barW, base } = model;
  const hasBand = pts.some((p) => p.min != null && p.max != null && p.min !== p.max);
  const gid = `area-${series.identifier.replace(/[^a-z0-9]/gi, "")}`;

  const areaPath = `${smoothPath(linePts, 0.55)} L ${linePts[n - 1][0]} ${base} L ${linePts[0][0]} ${base} Z`;
  const bandPath = hasBand
    ? `${smoothPath(bandTop, 0.55)} L ${bandBot[n - 1][0]} ${bandBot[n - 1][1]} ${smoothPath([...bandBot].reverse(), 0.55).replace(/^M/, "L")} Z`
    : "";

  function onMove(e: React.PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * w;
    let best = 0;
    let bestD = Infinity;
    for (let i = 0; i < n; i++) {
      const d = Math.abs(sx(i) - x);
      if (d < bestD) { bestD = d; best = i; }
    }
    setHover(best);
  }

  const hp = hover != null ? pts[hover] : null;
  const hx = hover != null ? sx(hover) : 0;

  return (
    <div ref={wrapRef} style={{ position: "relative", width: "100%" }}>
      <svg
        width="100%"
        height={height}
        viewBox={`0 0 ${w} ${height}`}
        preserveAspectRatio="none"
        role="img"
        aria-label={`${series.identifier} trend chart`}
        onPointerMove={onMove}
        onPointerLeave={() => setHover(null)}
        style={{ touchAction: "none", display: "block" }}
      >
        <defs>
          <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={isBar ? 0.0 : 0.26} />
            <stop offset="100%" stopColor={color} stopOpacity="0" />
          </linearGradient>
        </defs>

        {/* gridlines */}
        {grid.map((g, i) => (
          <g key={i}>
            <line x1={PAD.left} y1={g.y} x2={w - PAD.right} y2={g.y} stroke="var(--border)" strokeOpacity={0.6} />
            <text x={PAD.left - 8} y={g.y + 3} textAnchor="end" fontSize="10.5" fill="var(--faint)" className="mono">
              {formatValue(g.val)}
            </text>
          </g>
        ))}

        {/* x labels */}
        {xlabels.map((d) => (
          <text key={d.i} x={d.x} y={height - 9} textAnchor="middle" fontSize="10.5" fill="var(--faint)" className="mono">
            {tickLabel(d.t, series.bucketMs)}
          </text>
        ))}

        {isBar ? (
          pts.map((p, i) => {
            const x = sx(i) - barW / 2;
            const y = Math.min(sy(p.value), base);
            const h = Math.abs(base - sy(p.value));
            const active = hover === i;
            return (
              <rect
                key={i}
                x={x}
                y={y}
                width={barW}
                height={Math.max(0.5, h)}
                rx={Math.min(barW / 2, 3)}
                fill={color}
                fillOpacity={hover == null || active ? 0.92 : 0.34}
              />
            );
          })
        ) : (
          <>
            {hasBand && <path d={bandPath} fill={color} fillOpacity={0.12} />}
            <path d={areaPath} fill={`url(#${gid})`} />
            <path className="fadein" d={smoothPath(linePts, 0.55)} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
          </>
        )}

        {/* crosshair */}
        {hp && (
          <>
            <line x1={hx} y1={PAD.top} x2={hx} y2={height - PAD.bottom} stroke="var(--border-strong)" />
            <circle cx={hx} cy={sy(hp.value)} r={4.5} fill={color} stroke="var(--bg)" strokeWidth={2} />
          </>
        )}
      </svg>

      {hp && (
        <div
          className="chart-tip"
          style={{
            left: `${(hx / w) * 100}%`,
            top: `${(sy(hp.value) / height) * 100}%`,
          }}
        >
          <div style={{ color: "var(--muted)", fontSize: 11, marginBottom: 2 }}>
            {bucketLabel(hp.t, series.bucketMs)}
          </div>
          <div style={{ fontWeight: 600 }}>
            {formatValue(hp.value)} <span style={{ color: "var(--muted)", fontWeight: 400 }}>{displayUnit(series.unit)}</span>
          </div>
          {hp.min != null && hp.max != null && hp.min !== hp.max && (
            <div style={{ color: "var(--muted)", fontSize: 11, marginTop: 2 }}>
              {formatValue(hp.min)}–{formatValue(hp.max)} {displayUnit(series.unit)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
