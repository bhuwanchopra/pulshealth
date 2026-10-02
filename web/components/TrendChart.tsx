"use client";

// The metric detail chart: a hand-drawn SVG line (with a min–max band) or bar
// series that the reader can inspect and zoom without a chart library.
//
//   hover / arrow keys   → crosshair + tooltip for the nearest bucket
//   click / tap          → pins that bucket until another is picked or Escape
//   wheel, trackpad pinch, two-finger pinch → zoom about the pointer
//   horizontal drag, horizontal wheel      → pan while zoomed
//   Reset (shown while zoomed)             → the full selected range again
//
// The time-domain arithmetic lives in lib/chartDomain.ts (pure, unit-tested);
// this file is the rendering and the pointer plumbing. The visible window
// and selection are local state keyed to the `series.points` array, so a new
// range from the server starts from the full window with nothing pinned, and
// a one-finger touch drag only pans once zoomed — `touch-action: pan-y` keeps
// the page scrolling otherwise.

import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { makeScale, niceBounds, smoothPath, type Pt } from "@/lib/chart";
import {
  dataDomainOf,
  isZoomed,
  minimumSpan,
  nearestIndex,
  panDomain,
  spanOf,
  stepIndex,
  timeToX,
  type TimeDomain,
  visibleRange,
  wheelZoomScale,
  xToTime,
  zoomDomain,
} from "@/lib/chartDomain";
import { displayUnit, formatBucket, formatValue, formatWindow, tickLabel } from "@/lib/format";
import type { Series, SeriesPoint } from "@/lib/types";

const PAD = { top: 16, right: 16, bottom: 28, left: 46 };
// A press that travels less than this is a click/tap, not a drag.
const DRAG_THRESHOLD_PX = 4;
// Keyboard +/- zoom step.
const KEY_ZOOM = 1.5;

interface Keyed<T> {
  pts: SeriesPoint[];
  value: T;
}

interface Gesture {
  kind: "press" | "pinch";
  pointerId: number;
  startClientX: number;
  startDomain: TimeDomain;
  moved: boolean;
  lastDist: number;
}

export function TrendChart({
  series,
  color,
  height = 300,
  name,
}: {
  series: Series;
  color: string;
  height?: number;
  name?: string;
}) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const [w, setW] = useState(720);
  const [hover, setHover] = useState<number | null>(null);
  // Keyed to the points array so a new series (another range from the server)
  // starts unzoomed and unpinned without an effect.
  const [zoom, setZoom] = useState<Keyed<TimeDomain> | null>(null);
  const [pin, setPin] = useState<Keyed<number> | null>(null);
  const readoutId = useId();

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
  const bucketMs = series.bucketMs;
  const isBar = series.agg === "sum";
  const unit = displayUnit(series.unit);
  const n = pts.length;

  const times = useMemo(() => pts.map((p) => p.t), [pts]);
  const dataDomain = useMemo(() => dataDomainOf(times, bucketMs), [times, bucketMs]);
  const minSpan = dataDomain ? minimumSpan(dataDomain, bucketMs, n) : 0;
  const domain = zoom && zoom.pts === pts && dataDomain ? zoom.value : dataDomain;
  const pinned = pin && pin.pts === pts ? pin.value : null;
  const zoomed = !!(domain && dataDomain && isZoomed(domain, dataDomain));

  const innerW = w - PAD.left - PAD.right;
  const innerH = height - PAD.top - PAD.bottom;

  const model = useMemo(() => {
    if (!n || !domain) return null;
    const [from, to] = visibleRange(times, bucketMs, domain);
    const vis = pts.slice(from, to);
    if (!vis.length) return null;

    // Axis bounds follow the visible window, so zooming in reveals detail.
    const values = vis.map((p) => p.value).filter(Number.isFinite);
    const mins = vis.map((p) => p.min ?? p.value).filter(Number.isFinite);
    const maxs = vis.map((p) => p.max ?? p.value).filter(Number.isFinite);
    let lo = Math.min(...mins, ...values);
    let hi = Math.max(...maxs, ...values);
    if (isBar) lo = Math.min(0, lo);
    [lo, hi] = niceBounds(lo, hi);

    // A bucket is drawn at its centre.
    const sx = (t: number) => timeToX(t + bucketMs / 2, domain, PAD.left, innerW);
    const sy = makeScale(lo, hi, PAD.top + innerH, PAD.top);

    const linePts: Pt[] = vis.map((p) => [sx(p.t), sy(p.value)]);
    const bandTop: Pt[] = vis.map((p) => [sx(p.t), sy(p.max ?? p.value)]);
    const bandBot: Pt[] = vis.map((p) => [sx(p.t), sy(p.min ?? p.value)]);

    const ticks = 4;
    const grid = Array.from({ length: ticks + 1 }, (_, i) => {
      const val = lo + ((hi - lo) * i) / ticks;
      return { y: sy(val), val };
    });

    // About six x labels across the visible window, inside the plot.
    const m = vis.length;
    const labelEvery = Math.max(1, Math.round(m / 6));
    const xlabels = vis
      .map((p, i) => ({ i: from + i, x: sx(p.t), t: p.t }))
      .filter((d, i) => (i % labelEvery === 0 || i === m - 1) && d.x >= PAD.left && d.x <= w - PAD.right);

    const barW = isBar ? Math.max(2, (innerW * bucketMs) / spanOf(domain) * 0.62) : 0;
    const base = sy(isBar ? 0 : lo);
    const hasBand = !isBar && vis.some((p) => p.min != null && p.max != null && p.min !== p.max);
    const last = linePts.length - 1;
    const areaPath = `${smoothPath(linePts, 0.55)} L ${linePts[last][0]} ${base} L ${linePts[0][0]} ${base} Z`;
    const bandPath = hasBand
      ? `${smoothPath(bandTop, 0.55)} L ${bandBot[last][0]} ${bandBot[last][1]} ${smoothPath([...bandBot].reverse(), 0.55).replace(/^M/, "L")} Z`
      : "";

    return { from, to, vis, sx, sy, grid, xlabels, barW, base, hasBand, areaPath, bandPath, linePath: smoothPath(linePts, 0.55) };
  }, [n, domain, times, bucketMs, pts, isBar, innerW, innerH, w]);

  // The wheel listener and pointer handlers read the latest geometry through a
  // ref, so the non-passive wheel listener is registered once.
  const latest = useRef({ domain, dataDomain, minSpan, w, innerW, bucketMs, model, pts, pinned, zoomed });
  useLayoutEffect(() => {
    latest.current = { domain, dataDomain, minSpan, w, innerW, bucketMs, model, pts, pinned, zoomed };
  });

  const applyDomain = useCallback((next: TimeDomain) => {
    const { pts: cur, dataDomain: dd } = latest.current;
    if (!dd) return;
    setZoom(isZoomed(next, dd) ? { pts: cur, value: next } : null);
  }, []);

  // clientX → epoch ms at that pointer position (inside the visible window).
  const clientXToTime = useCallback((clientX: number): number | null => {
    const svg = svgRef.current;
    const { domain: d, w: width, innerW: iw } = latest.current;
    if (!svg || !d) return null;
    const rect = svg.getBoundingClientRect();
    const x = ((clientX - rect.left) / rect.width) * width;
    return xToTime(x, d, PAD.left, iw);
  }, []);

  // The visible bucket nearest to a pointer position.
  const indexAtClientX = useCallback(
    (clientX: number): number | null => {
      const t = clientXToTime(clientX);
      const { model: m, bucketMs: b } = latest.current;
      if (t == null || !m) return null;
      const centre = Math.max(times[m.from], Math.min(times[m.to - 1], t - b / 2));
      return nearestIndex(times, centre);
    },
    [clientXToTime, times],
  );

  // Wheel: zoom about the pointer; a horizontal wheel (two-finger swipe) pans
  // while zoomed. The page keeps scrolling when the chart has nothing to do —
  // preventDefault only when the window actually changes (and for a ctrlKey
  // pinch, which would otherwise zoom the whole page).
  useEffect(() => {
    const svg = svgRef.current;
    if (!svg) return;
    const onWheel = (e: WheelEvent) => {
      const { domain: d, dataDomain: dd, minSpan: ms, innerW: iw } = latest.current;
      if (!d || !dd) return;
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
        if (!isZoomed(d, dd)) return;
        const delta = (e.deltaX / iw) * spanOf(d);
        const next = panDomain(d, delta, dd);
        if (next.start !== d.start) {
          e.preventDefault();
          applyDomain(next);
        }
        return;
      }
      const centre = clientXToTime(e.clientX);
      if (centre == null) return;
      const next = zoomDomain(d, centre, wheelZoomScale(e.deltaY, e.deltaMode, e.ctrlKey), dd, ms);
      if (next.start !== d.start || next.end !== d.end) {
        e.preventDefault();
        applyDomain(next);
      } else if (e.ctrlKey) {
        e.preventDefault();
      }
    };
    svg.addEventListener("wheel", onWheel, { passive: false });
    return () => svg.removeEventListener("wheel", onWheel);
  }, [applyDomain, clientXToTime]);

  // Pointer plumbing. One pointer: press → tap (pin) or, while zoomed, drag
  // (pan). Two pointers: pinch about their midpoint. Mouse and pen hover.
  const pointers = useRef(new Map<number, number>()); // pointerId → clientX
  const gesture = useRef<Gesture | null>(null);

  function pinchDistance(): number {
    const xs = [...pointers.current.values()];
    return xs.length >= 2 ? Math.abs(xs[0] - xs[1]) : 0;
  }
  function pinchMidpoint(): number {
    const xs = [...pointers.current.values()];
    return xs.length >= 2 ? (xs[0] + xs[1]) / 2 : (xs[0] ?? 0);
  }

  function onPointerDown(e: React.PointerEvent<SVGSVGElement>) {
    const { domain: d } = latest.current;
    if (!d) return;
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // A synthetic event has no active pointer to capture; the gesture still works.
    }
    pointers.current.set(e.pointerId, e.clientX);
    if (pointers.current.size >= 2) {
      gesture.current = { kind: "pinch", pointerId: e.pointerId, startClientX: e.clientX, startDomain: d, moved: true, lastDist: pinchDistance() };
      setHover(null);
    } else {
      gesture.current = { kind: "press", pointerId: e.pointerId, startClientX: e.clientX, startDomain: d, moved: false, lastDist: 0 };
    }
  }

  function onPointerMove(e: React.PointerEvent<SVGSVGElement>) {
    const g = gesture.current;
    const { dataDomain: dd, minSpan: ms, innerW: iw } = latest.current;
    if (pointers.current.has(e.pointerId)) pointers.current.set(e.pointerId, e.clientX);

    if (g?.kind === "pinch" && dd && pointers.current.size >= 2) {
      const dist = pinchDistance();
      if (g.lastDist > 0 && dist > 0) {
        const centre = clientXToTime(pinchMidpoint());
        const { domain: d } = latest.current;
        if (centre != null && d) applyDomain(zoomDomain(d, centre, dist / g.lastDist, dd, ms));
      }
      g.lastDist = dist;
      return;
    }

    if (g?.kind === "press" && g.pointerId === e.pointerId && dd) {
      const dx = e.clientX - g.startClientX;
      if (!g.moved && Math.abs(dx) < DRAG_THRESHOLD_PX) return;
      g.moved = true;
      if (isZoomed(g.startDomain, dd)) {
        const delta = (-dx / iw) * spanOf(g.startDomain);
        applyDomain(panDomain(g.startDomain, delta, dd));
        setHover(null);
      }
      return;
    }

    if (!g && e.pointerType !== "touch") {
      const i = indexAtClientX(e.clientX);
      setHover(i);
    }
  }

  function endPointer(e: React.PointerEvent<SVGSVGElement>, cancelled: boolean) {
    const g = gesture.current;
    pointers.current.delete(e.pointerId);
    if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId);
    if (!g) return;
    if (g.kind === "press" && g.pointerId === e.pointerId) {
      gesture.current = null;
      if (!cancelled && !g.moved) {
        const i = indexAtClientX(e.clientX);
        if (i != null) {
          const { pinned: cur, pts: p } = latest.current;
          setPin(cur === i ? null : { pts: p, value: i });
          if (e.pointerType === "touch") setHover(null);
        }
      }
      return;
    }
    // A pinch ends when either finger lifts; the remaining finger does nothing
    // until it lifts too, so a pinch never turns into an accidental pan.
    if (pointers.current.size === 0) gesture.current = null;
    else g.lastDist = 0;
  }

  function onPointerLeave() {
    if (!gesture.current) setHover(null);
  }

  function reset() {
    setZoom(null);
    setPin(null);
    setHover(null);
  }

  function reveal(i: number) {
    // Pan the window so the bucket is visible, if it fell outside it.
    const { domain: d, dataDomain: dd } = latest.current;
    if (!d || !dd) return;
    const t = times[i];
    if (t < d.start) applyDomain(panDomain(d, t - d.start, dd));
    else if (t + bucketMs > d.end) applyDomain(panDomain(d, t + bucketMs - d.end, dd));
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
    if (!n || !domain || !dataDomain) return;
    const active = pinned ?? hover;
    const select = (i: number) => {
      setPin({ pts, value: i });
      setHover(null);
      reveal(i);
    };
    switch (e.key) {
      case "ArrowLeft":
        select(stepIndex(active, -1, n));
        break;
      case "ArrowRight":
        select(stepIndex(active, 1, n));
        break;
      case "PageUp":
        select(stepIndex(active, -Math.max(1, Math.round(n / 10)), n));
        break;
      case "PageDown":
        select(stepIndex(active, Math.max(1, Math.round(n / 10)), n));
        break;
      case "Home":
        select(0);
        break;
      case "End":
        select(n - 1);
        break;
      case "+":
      case "=":
      case "-":
      case "_": {
        const centre = active != null ? times[active] + bucketMs / 2 : domain.start + spanOf(domain) / 2;
        applyDomain(zoomDomain(domain, centre, e.key === "-" || e.key === "_" ? 1 / KEY_ZOOM : KEY_ZOOM, dataDomain, minSpan));
        break;
      }
      case "Escape":
        if (pinned != null) setPin(null);
        else if (zoomed) setZoom(null);
        else return;
        break;
      case "0":
        if (!zoomed) return;
        setZoom(null);
        break;
      default:
        return;
    }
    e.preventDefault();
  }

  const chartName = name ?? series.identifier;
  const gid = `area-${series.identifier.replace(/[^a-z0-9]/gi, "")}`;
  const clipId = `clip-${gid}`;

  if (!n || !model || !domain) {
    return (
      <div ref={wrapRef} style={{ height: height + 30, display: "grid", placeItems: "center" }}>
        <span className="muted" style={{ color: "var(--muted)", fontSize: 14 }}>No data in this range.</span>
      </div>
    );
  }

  const { from, to, sx, sy, grid, xlabels, barW, base, hasBand, areaPath, bandPath, linePath } = model;
  const activeIdx = hover ?? pinned;
  const active = activeIdx != null && activeIdx >= from && activeIdx < to ? pts[activeIdx] : null;
  const ax = active ? sx(active.t) : 0;
  const ay = active ? sy(active.value) : 0;
  const pinnedPt = pinned != null && pinned !== activeIdx && pinned >= from && pinned < to ? pts[pinned] : null;
  const showRange = (p: SeriesPoint) => p.min != null && p.max != null && p.min !== p.max;

  // Flip the tooltip inward near the edges rather than letting it overflow.
  const tipShift = ax < w * 0.22 ? "-8%" : ax > w * 0.78 ? "-92%" : "-50%";

  const windowText = formatWindow(domain.start, domain.end, bucketMs);

  return (
    <div ref={wrapRef} style={{ position: "relative", width: "100%" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, minHeight: 30, marginBottom: 2, fontSize: 12, color: "var(--muted)" }}>
        <div id={readoutId} aria-live="polite" aria-atomic="true" className="tabular" style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {active ? (
            <>
              <span>{formatBucket(active.t, bucketMs)}</span>
              <span style={{ color: "var(--fg)", fontWeight: 600, marginLeft: 10 }}>
                {formatValue(active.value)}
                {unit && ` ${unit}`}
              </span>
              {showRange(active) && (
                <span style={{ marginLeft: 10 }}>
                  {formatValue(active.min)}–{formatValue(active.max)}
                  {unit && ` ${unit}`}
                </span>
              )}
              {pinned === activeIdx && <span style={{ marginLeft: 8, color: "var(--faint)" }}>pinned</span>}
            </>
          ) : zoomed ? (
            <span style={{ color: "var(--faint)" }}>Showing {windowText}</span>
          ) : (
            <span style={{ color: "var(--faint)" }}>Hover, tap or use the arrow keys for a value · scroll or pinch to zoom</span>
          )}
        </div>
        {zoomed && (
          <button type="button" className="chart-reset" onClick={reset} aria-label={`Reset zoom to the full ${chartName} range`}>
            Reset
          </button>
        )}
      </div>

      <div
        role="application"
        tabIndex={0}
        aria-label={`${chartName} trend chart. Arrow keys move between points, plus and minus zoom, Escape clears.`}
        aria-describedby={readoutId}
        onKeyDown={onKeyDown}
        onBlur={(e) => {
          if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setHover(null);
        }}
        className="chart-focus"
        style={{ position: "relative", borderRadius: 8 }}
      >
        <svg
          ref={svgRef}
          width="100%"
          height={height}
          viewBox={`0 0 ${w} ${height}`}
          preserveAspectRatio="none"
          aria-hidden="true"
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={(e) => endPointer(e, false)}
          onPointerCancel={(e) => endPointer(e, true)}
          onPointerLeave={onPointerLeave}
          style={{
            touchAction: "pan-y",
            display: "block",
            userSelect: "none",
            WebkitUserSelect: "none",
            cursor: zoomed ? "grab" : "crosshair",
          }}
        >
          <defs>
            <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={isBar ? 0.0 : 0.26} />
              <stop offset="100%" stopColor={color} stopOpacity="0" />
            </linearGradient>
            <clipPath id={clipId}>
              <rect x={PAD.left} y={0} width={innerW} height={height - PAD.bottom + 4} />
            </clipPath>
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
              {tickLabel(d.t, bucketMs)}
            </text>
          ))}

          <g clipPath={`url(#${clipId})`}>
            {isBar ? (
              pts.slice(from, to).map((p, k) => {
                const i = from + k;
                const x = sx(p.t) - barW / 2;
                const y = Math.min(sy(p.value), base);
                const h = Math.abs(base - sy(p.value));
                const isActive = activeIdx === i || pinned === i;
                return (
                  <rect
                    key={p.t}
                    x={x}
                    y={y}
                    width={barW}
                    height={Math.max(0.5, h)}
                    rx={Math.min(barW / 2, 3)}
                    fill={color}
                    fillOpacity={activeIdx == null || isActive ? 0.92 : 0.34}
                  />
                );
              })
            ) : (
              <>
                {hasBand && <path d={bandPath} fill={color} fillOpacity={0.12} />}
                <path d={areaPath} fill={`url(#${gid})`} />
                <path className="fadein" d={linePath} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
              </>
            )}
          </g>

          {/* a pinned bucket other than the hovered one keeps a marker */}
          {pinnedPt && (
            <circle cx={sx(pinnedPt.t)} cy={sy(pinnedPt.value)} r={4} fill="none" stroke={color} strokeWidth={2} />
          )}

          {/* crosshair */}
          {active && (
            <>
              <line x1={ax} y1={PAD.top} x2={ax} y2={height - PAD.bottom} stroke="var(--border-strong)" />
              <circle cx={ax} cy={ay} r={4.5} fill={color} stroke="var(--bg)" strokeWidth={2} />
              {pinned === activeIdx && <circle cx={ax} cy={ay} r={8} fill="none" stroke={color} strokeOpacity={0.5} strokeWidth={1.5} />}
            </>
          )}
        </svg>

        {active && (
          <div
            className="chart-tip"
            style={{
              left: `${(ax / w) * 100}%`,
              top: `${(ay / height) * 100}%`,
              transform: `translate(${tipShift}, -120%)`,
            }}
          >
            <div style={{ color: "var(--muted)", fontSize: 11, marginBottom: 2 }}>{formatBucket(active.t, bucketMs)}</div>
            <div style={{ fontWeight: 600 }}>
              {formatValue(active.value)}
              {unit && <span style={{ color: "var(--muted)", fontWeight: 400 }}> {unit}</span>}
            </div>
            {showRange(active) && (
              <div style={{ color: "var(--muted)", fontSize: 11, marginTop: 2 }}>
                {formatValue(active.min)}–{formatValue(active.max)}
                {unit && ` ${unit}`}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
