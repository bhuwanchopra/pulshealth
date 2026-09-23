"use client";

import { useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  makeScale,
  niceBounds,
  panDomain,
  smoothPath,
  zoomDomain,
  type ChartDomain,
  type Pt,
} from "@/lib/chart";
import { displayUnit, formatValue, formatFull, tickLabel } from "@/lib/format";
import type { Series } from "@/lib/types";

const PAD = { top: 16, right: 16, bottom: 28, left: 46 };
const MIN_ZOOM_POINTS = 3;
const WHEEL_ZOOM = 1.15;

type Pointer = { x: number; y: number };
type Gesture = {
  pointers: Map<number, Pointer>;
  startDistance: number | null;
  startDomain: ChartDomain;
  startPointerX: number;
};

export function TrendChart({
  series,
  color,
  height = 300,
}: {
  series: Series;
  color: string;
  height?: number;
}) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const [w, setW] = useState(720);
  const [hover, setHover] = useState<number | null>(null);
  const [domain, setDomain] = useState<ChartDomain>([0, Math.max(1, series.points.length - 1)]);
  const gestureRef = useRef<Gesture | null>(null);

  const pts = series.points;
  const isBar = series.agg === "sum";
  const fullMax = Math.max(0, pts.length - 1);
  const isZoomed = effectiveDomain[0] > 0.01 || effectiveDomain[1] < fullMax - 0.01;

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

  const domainKey = series.identifier + ":" + pts.length + ":" + series.bucketMs;
  const initialDomain: ChartDomain = [0, Math.max(1, pts.length - 1)];
  const [domainKeyState, setDomainKeyState] = useState(domainKey);
  const effectiveDomain = domainKeyState === domainKey ? domain : initialDomain;

  const model = useMemo(() => {
    const innerW = w - PAD.left - PAD.right;
    const innerH = height - PAD.top - PAD.bottom;
    if (!pts.length) return null;

    const visibleStart = Math.max(0, Math.floor(effectiveDomain[0]));
    const visibleEnd = Math.min(pts.length - 1, Math.ceil(effectiveDomain[1]));
    const visible = pts.slice(visibleStart, visibleEnd + 1);
    const values = visible.map((p) => p.value).filter(Number.isFinite);
    const mins = visible.map((p) => p.min ?? p.value).filter(Number.isFinite);
    const maxs = visible.map((p) => p.max ?? p.value).filter(Number.isFinite);
    let lo = Math.min(...mins);
    let hi = Math.max(...maxs, ...values);
    if (isBar) lo = Math.min(0, lo);
    [lo, hi] = niceBounds(lo, hi);

    const sx = isBar
      ? (i: number) => PAD.left + (innerW * (i - effectiveDomain[0] + 0.5)) / Math.max(1, effectiveDomain[1] - effectiveDomain[0] + 1)
      : makeScale(effectiveDomain[0], Math.max(effectiveDomain[0] + 1, effectiveDomain[1]), PAD.left, PAD.left + innerW);
    const sy = makeScale(lo, hi, PAD.top + innerH, PAD.top);

    const linePts: Pt[] = visible.map((p, offset) => [sx(visibleStart + offset), sy(p.value)]);
    const bandTop: Pt[] = visible.map((p, offset) => [sx(visibleStart + offset), sy(p.max ?? p.value)]);
    const bandBot: Pt[] = visible.map((p, offset) => [sx(visibleStart + offset), sy(p.min ?? p.value)]);

    const grid = Array.from({ length: 5 }, (_, i) => {
      const val = lo + ((hi - lo) * i) / 4;
      return { y: sy(val), val };
    });

    const labelCount = isZoomed ? 6 : 6;
    const span = Math.max(1, effectiveDomain[1] - effectiveDomain[0]);
    const step = Math.max(1, Math.ceil(span / labelCount));
    const first = Math.ceil(effectiveDomain[0] / step) * step;
    const xlabels: { i: number; x: number; t: number }[] = [];
    for (let i = first; i <= effectiveDomain[1] + 0.001; i += step) {
      const index = Math.min(pts.length - 1, Math.max(0, Math.round(i)));
      if (!xlabels.some((d) => d.i === index)) xlabels.push({ i: index, x: sx(i), t: pts[index].t });
    }
    for (const i of [Math.round(effectiveDomain[0]), Math.round(effectiveDomain[1])]) {
      const index = Math.min(pts.length - 1, Math.max(0, i));
      if (!xlabels.some((d) => d.i === index)) xlabels.push({ i: index, x: sx(index), t: pts[index].t });
    }
    xlabels.sort((a, b) => a.x - b.x);

    const barW = isBar ? Math.max(2, (innerW / Math.max(1, effectiveDomain[1] - effectiveDomain[0] + 1)) * 0.62) : 0;
    return {
      innerW, innerH, sx, sy, lo, hi, linePts, bandTop, bandBot,
      grid, xlabels, visibleStart, visibleEnd, barW,
      base: sy(isBar ? 0 : lo),
    };
  }, [pts, w, height, domain, isBar, isZoomed]);

  if (!pts.length || !model) {
    return (
      <div ref={wrapRef} style={{ height, display: "grid", placeItems: "center" }}>
        <span className="muted" style={{ color: "var(--muted)", fontSize: 14 }}>No data in this range.</span>
      </div>
    );
  }

  const { sx, sy, linePts, bandTop, bandBot, grid, xlabels, visibleStart, visibleEnd, barW, base } = model;
  const hasBand = pts.slice(visibleStart, visibleEnd + 1).some((p) => p.min != null && p.max != null && p.min !== p.max);
  const gid = `area-${series.identifier.replace(/[^a-z0-9]/gi, "")}`;
  const areaPath = linePts.length
    ? `${smoothPath(linePts, 0.55)} L ${linePts[linePts.length - 1][0]} ${base} L ${linePts[0][0]} ${base} Z`
    : "";
  const bandPath = hasBand
    ? `${smoothPath(bandTop, 0.55)} L ${bandBot[bandBot.length - 1][0]} ${bandBot[bandBot.length - 1][1]} ${smoothPath([...bandBot].reverse(), 0.55).replace(/^M/, "L")} Z`
    : "";

  function indexAtClientX(clientX: number) {
    const svg = svgRef.current;
    if (!svg) return 0;
    const rect = svg.getBoundingClientRect();
    const chartX = PAD.left + ((clientX - rect.left) / rect.width) * w;
    const raw = effectiveDomain[0] + ((chartX - PAD.left) / (w - PAD.left - PAD.right)) * (effectiveDomain[1] - effectiveDomain[0]);
    return Math.max(0, Math.min(pts.length - 1, Math.round(raw)));
  }

  function applyWheel(e: React.WheelEvent<SVGSVGElement>) {
    e.preventDefault();
    const rect = e.currentTarget.getBoundingClientRect();
    const chartX = PAD.left + ((e.clientX - rect.left) / rect.width) * w;
    const center = effectiveDomain[0] + ((chartX - PAD.left) / (w - PAD.left - PAD.right)) * (effectiveDomain[1] - effectiveDomain[0]);
    const factor = e.deltaY < 0 ? WHEEL_ZOOM : 1 / WHEEL_ZOOM;
    setDomainKeyState(domainKey);
    setDomain((d) => zoomDomain(d, center, factor, 0, fullMax, MIN_ZOOM_POINTS));
  }

  function onPointerDown(e: React.PointerEvent<SVGSVGElement>) {
    e.currentTarget.setPointerCapture(e.pointerId);
    const rect = e.currentTarget.getBoundingClientRect();
    const p = { x: e.clientX - rect.left, y: e.clientY - rect.top };
    const existing = gestureRef.current;
    if (!existing) {
      gestureRef.current = {
        pointers: new Map([[e.pointerId, p]]),
        startDistance: null,
        startDomain: domain,
        startPointerX: p.x,
      };
    } else {
      existing.pointers.set(e.pointerId, p);
      if (existing.pointers.size === 2) {
        const [a, b] = [...existing.pointers.values()];
        existing.startDistance = Math.hypot(a.x - b.x, a.y - b.y);
        existing.startDomain = domain;
        existing.startPointerX = p.x;
      }
    }
    setHover(indexAtClientX(e.clientX));
  }

  function onPointerMove(e: React.PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    const p = { x: e.clientX - rect.left, y: e.clientY - rect.top };
    const g = gestureRef.current;
    if (g?.pointers.has(e.pointerId)) {
      g.pointers.set(e.pointerId, p);
      if (g.pointers.size === 2 && g.startDistance) {
        const [a, b] = [...g.pointers.values()];
        const distance = Math.max(1, Math.hypot(a.x - b.x, a.y - b.y));
        const factor = distance / g.startDistance;
        const rectWidth = Math.max(1, rect.width);
        const midpoint = (a.x + b.x) / 2;
        const chartMid = PAD.left + (midpoint / rectWidth) * w;
        const center = g.startDomain[0] + ((chartMid - PAD.left) / (w - PAD.left - PAD.right)) * (g.startDomain[1] - g.startDomain[0]);
        setDomainKeyState(domainKey);
        setDomain(zoomDomain(g.startDomain, center, factor, 0, fullMax, MIN_ZOOM_POINTS));
        return;
      }
      if (g.pointers.size === 1 && g.startDomain[1] - g.startDomain[0] < fullMax - 0.01) {
        const dx = p.x - g.startPointerX;
        const indexDelta = -(dx / Math.max(1, rect.width)) * (g.startDomain[1] - g.startDomain[0]);
        setDomainKeyState(domainKey);
        setDomain(panDomain(g.startDomain, indexDelta, 0, fullMax));
        return;
      }
    }
    setHover(indexAtClientX(e.clientX));
  }

  function onPointerUp(e: React.PointerEvent<SVGSVGElement>) {
    const g = gestureRef.current;
    if (g) {
      g.pointers.delete(e.pointerId);
      if (g.pointers.size === 0) gestureRef.current = null;
      else if (g.pointers.size === 1) {
        const [p] = [...g.pointers.values()];
        g.startDomain = domain;
        g.startPointerX = p.x;
        g.startDistance = null;
        g.pointers = new Map([[e.pointerId, p]]);
      }
    }
  }

  function onDoubleClick() {
    setDomainKeyState(domainKey);
    setDomain([0, fullMax]);
    setHover(null);
  }

  const hoverIndex = hover != null && hover >= 0 && hover < pts.length ? hover : null;
  const hp = hoverIndex != null ? pts[hoverIndex] : null;
  const hx = hoverIndex != null ? sx(hoverIndex) : 0;

  return (
    <div ref={wrapRef} style={{ position: "relative", width: "100%" }}>
      <div style={{ display: "flex", justifyContent: "flex-end", gap: 8, marginBottom: 4, minHeight: 24 }}>
        {isZoomed && (
          <button
            type="button"
            onClick={() => { setDomainKeyState(domainKey); setDomain([0, fullMax]); setHover(null); }}
            aria-label="Reset chart zoom"
            style={{ fontSize: 11, padding: "3px 8px", borderRadius: 6 }}
          >
            Reset zoom
          </button>
        )}
      </div>
      <svg
        ref={svgRef}
        width="100%"
        height={height}
        viewBox={`0 0 ${w} ${height}`}
        preserveAspectRatio="none"
        role="img"
        aria-label={`${series.identifier} trend chart. Hover or tap a point to inspect its value. Pinch or scroll to zoom.`}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onPointerLeave={() => { if (!gestureRef.current?.pointers.size) setHover(null); }}
        onWheel={applyWheel}
        onDoubleClick={onDoubleClick}
        style={{ touchAction: "none", display: "block", cursor: isZoomed ? "crosshair" : "default" }}
      >
        <defs>
          <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={isBar ? 0.0 : 0.26} />
            <stop offset="100%" stopColor={color} stopOpacity="0" />
          </linearGradient>
        </defs>
        {grid.map((g, i) => (
          <g key={i}>
            <line x1={PAD.left} y1={g.y} x2={w - PAD.right} y2={g.y} stroke="var(--border)" strokeOpacity={0.6} />
            <text x={PAD.left - 8} y={g.y + 3} textAnchor="end" fontSize="10.5" fill="var(--faint)" className="mono">{formatValue(g.val)}</text>
          </g>
        ))}
        {xlabels.map((d) => (
          <text key={d.i} x={d.x} y={height - 9} textAnchor="middle" fontSize="10.5" fill="var(--faint)" className="mono">{tickLabel(d.t, series.bucketMs)}</text>
        ))}
        {isBar ? (
          pts.slice(visibleStart, visibleEnd + 1).map((p, offset) => {
            const i = visibleStart + offset;
            const x = sx(i) - barW / 2;
            const y = Math.min(sy(p.value), base);
            const h = Math.abs(base - sy(p.value));
            return (
              <rect key={i} x={x} y={y} width={barW} height={Math.max(0.5, h)} rx={Math.min(barW / 2, 3)}
                fill={color} fillOpacity={hover == null || hover === i ? 0.92 : 0.34} />
            );
          })
        ) : (
          <>
            {hasBand && <path d={bandPath} fill={color} fillOpacity={0.12} />}
            <path d={areaPath} fill={`url(#${gid})`} />
            <path className="fadein" d={smoothPath(linePts, 0.55)} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
          </>
        )}
        {hp && hoverIndex != null && hoverIndex >= visibleStart && hoverIndex <= visibleEnd && (
          <>
            <line x1={hx} y1={PAD.top} x2={hx} y2={height - PAD.bottom} stroke="var(--border-strong)" />
            <circle cx={hx} cy={sy(hp.value)} r={4.5} fill={color} stroke="var(--bg)" strokeWidth={2} />
          </>
        )}
      </svg>
      {hp && hoverIndex != null && hoverIndex >= visibleStart && hoverIndex <= visibleEnd && (
        <div className="chart-tip" style={{ left: `${(hx / w) * 100}%`, top: `${(sy(hp.value) / height) * 100}%` }}>
          <div style={{ color: "var(--muted)", fontSize: 11, marginBottom: 2 }}>{formatFull(hp.t)}</div>
          <div style={{ fontWeight: 600 }}>{formatValue(hp.value)} <span style={{ color: "var(--muted)", fontWeight: 400 }}>{displayUnit(series.unit)}</span></div>
          {hp.min != null && hp.max != null && hp.min !== hp.max && (
            <div style={{ color: "var(--muted)", fontSize: 11, marginTop: 2 }}>{formatValue(hp.min)}–{formatValue(hp.max)} {displayUnit(series.unit)}</div>
          )}
        </div>
      )}
    </div>
  );
}
