// Small, dependency-free helpers for hand-built SVG charts.

export type Pt = [number, number]; // pixel coords

// Cardinal spline → smooth SVG path. Tension 0 = Catmull-Rom.
export function smoothPath(pts: Pt[], tension = 0.5): string {
  if (pts.length === 0) return "";
  if (pts.length === 1) return `M ${pts[0][0]} ${pts[0][1]}`;
  if (pts.length === 2) return `M ${pts[0][0]} ${pts[0][1]} L ${pts[1][0]} ${pts[1][1]}`;
  const t = (1 - tension) / 6;
  let d = `M ${pts[0][0]} ${pts[0][1]}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[i + 2] ?? p2;
    const c1x = p1[0] + (p2[0] - p0[0]) * t;
    const c1y = p1[1] + (p2[1] - p0[1]) * t;
    const c2x = p2[0] - (p3[0] - p1[0]) * t;
    const c2y = p2[1] - (p3[1] - p1[1]) * t;
    d += ` C ${c1x} ${c1y} ${c2x} ${c2y} ${p2[0]} ${p2[1]}`;
  }
  return d;
}

export function linePath(pts: Pt[]): string {
  if (!pts.length) return "";
  return "M " + pts.map(([x, y]) => `${x} ${y}`).join(" L ");
}

// "Nice" axis bounds that give round-ish gridlines.
export function niceBounds(min: number, max: number): [number, number] {
  if (min === max) {
    const pad = Math.abs(min) * 0.1 || 1;
    return [min - pad, max + pad];
  }
  const range = max - min;
  const step = Math.pow(10, Math.floor(Math.log10(range))) / 2;
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  return [lo, hi];
}

// The smallest 1/2/5 × 10ⁿ step at least `raw` wide, and the decimals a label
// at that step needs (0.05 → 2, 20 → 0).
export function niceStep(raw: number): { step: number; decimals: number } {
  if (!(raw > 0) || !Number.isFinite(raw)) return { step: 1, decimals: 0 };
  const exp = Math.floor(Math.log10(raw));
  const m = [1, 2, 5].find((m) => m * 10 ** exp >= raw * (1 - 1e-9));
  return m ? { step: m * 10 ** exp, decimals: Math.max(0, -exp) } : { step: 10 ** (exp + 1), decimals: Math.max(0, -exp - 1) };
}

// Gridlines at the nice step that splits [min, max] into at most `count`
// intervals, with the bounds snapped outward to it. Labels come back as strings at the
// step's precision: per-sample workout values are often fractions (a resting
// energy sample is a few hundredths of a kcal), so rounding to integers would
// label every line 0.
export function niceTicks(min: number, max: number, count = 5): { lo: number; hi: number; ticks: { val: number; label: string }[] } {
  if (min === max) {
    const pad = Math.abs(min) * 0.1 || 1;
    min -= pad;
    max += pad;
  }
  const { step, decimals } = niceStep((max - min) / count);
  const first = Math.floor(min / step + 1e-9);
  const last = Math.ceil(max / step - 1e-9);
  const ticks = Array.from({ length: last - first + 1 }, (_, i) => {
    const val = (first + i) * step;
    return { val, label: val.toFixed(decimals) };
  });
  return { lo: first * step, hi: last * step, ticks };
}

export function makeScale(domainMin: number, domainMax: number, rangeMin: number, rangeMax: number) {
  const d = domainMax - domainMin || 1;
  return (v: number) => rangeMin + ((v - domainMin) / d) * (rangeMax - rangeMin);
}

export type ChartDomain = readonly [number, number];

export function clampDomain(domain: ChartDomain, min: number, max: number, minSpan = 2): ChartDomain {
  if (max <= min) return [min, min];
  const span = Math.min(Math.max(minSpan, domain[1] - domain[0]), max - min);
  let start = domain[0];
  start = Math.max(min, Math.min(start, max - span));
  return [start, start + span];
}

export function zoomDomain(domain: ChartDomain, center: number, factor: number, min: number, max: number, minSpan = 2): ChartDomain {
  if (!Number.isFinite(factor) || factor <= 0) return domain;
  const currentSpan = domain[1] - domain[0];
  if (currentSpan <= 0) return domain;
  const targetSpan = currentSpan / factor;
  const start = center - (center - domain[0]) * (targetSpan / currentSpan);
  const end = center + (domain[1] - center) * (targetSpan / currentSpan);
  const boundedSpan = Math.min(Math.max(minSpan, end - start), max - min);
  const centerRatio = (center - domain[0]) / currentSpan;
  const boundedStart = Math.min(
    max - boundedSpan,
    Math.max(min, center - centerRatio * boundedSpan),
  );
  return [boundedStart, boundedStart + boundedSpan];
}

export function panDomain(domain: ChartDomain, delta: number, min: number, max: number): ChartDomain {
  const span = domain[1] - domain[0];
  if (span >= max - min) return [min, max];
  let start = domain[0] + delta;
  start = Math.max(min, Math.min(start, max - span));
  return [start, start + span];
}
