// Pure time-domain arithmetic for the interactive trend chart: zoom, pan,
// clamping and nearest-point lookup. Nothing here touches the DOM or React,
// so lib/chartDomain.test.ts pins the behaviour the gestures rely on.

export interface TimeDomain {
  start: number; // epoch ms, inclusive
  end: number; // epoch ms, exclusive
}

/** How many buckets a zoom may narrow the window to (unless the data holds fewer). */
export const MIN_VISIBLE_POINTS = 5;

export function spanOf(d: TimeDomain): number {
  return d.end - d.start;
}

/** The full extent a series covers: first bucket start through the end of the last bucket. */
export function dataDomainOf(times: readonly number[], bucketMs: number): TimeDomain | null {
  if (!times.length) return null;
  return { start: times[0], end: times[times.length - 1] + bucketMs };
}

/**
 * The narrowest window a zoom may reach: MIN_VISIBLE_POINTS buckets, or the
 * whole series when it has fewer than that.
 */
export function minimumSpan(dataDomain: TimeDomain, bucketMs: number, pointCount: number): number {
  const full = spanOf(dataDomain);
  if (pointCount <= MIN_VISIBLE_POINTS) return full;
  return Math.min(full, bucketMs * MIN_VISIBLE_POINTS);
}

/**
 * Keep `domain` inside `dataDomain`, at least `minimumSpan` wide and never
 * wider than the data. A window pushed past an edge slides back rather than
 * shrinking, so panning at the boundary stops cleanly.
 */
export function clampDomain(domain: TimeDomain, dataDomain: TimeDomain, minimumSpan: number): TimeDomain {
  const full = spanOf(dataDomain);
  const minSpan = Math.max(0, Math.min(minimumSpan, full));
  let span = spanOf(domain);
  if (!Number.isFinite(span) || span < minSpan) span = minSpan;
  if (span > full) span = full;
  let start = Number.isFinite(domain.start) ? domain.start : dataDomain.start;
  if (start < dataDomain.start) start = dataDomain.start;
  if (start + span > dataDomain.end) start = dataDomain.end - span;
  return { start, end: start + span };
}

/**
 * Scale the window about `center` (an epoch ms inside it). `scale` > 1 zooms
 * in (the span divides by it), < 1 zooms out. The point under `center` stays
 * under the pointer, so wheel and pinch zoom feel anchored.
 */
export function zoomDomain(
  domain: TimeDomain,
  center: number,
  scale: number,
  dataDomain: TimeDomain,
  minimumSpan: number,
): TimeDomain {
  if (!(scale > 0) || !Number.isFinite(scale) || scale === 1) return clampDomain(domain, dataDomain, minimumSpan);
  const span = spanOf(domain);
  const ratio = span > 0 ? (center - domain.start) / span : 0.5;
  const nextSpan = span / scale;
  const start = center - ratio * nextSpan;
  return clampDomain({ start, end: start + nextSpan }, dataDomain, minimumSpan);
}

/** Slide the window by `delta` ms (positive = later), stopping at the data's edges. */
export function panDomain(domain: TimeDomain, delta: number, dataDomain: TimeDomain): TimeDomain {
  if (!Number.isFinite(delta) || delta === 0) return domain;
  const span = spanOf(domain);
  return clampDomain({ start: domain.start + delta, end: domain.end + delta }, dataDomain, span);
}

export function isZoomed(domain: TimeDomain, dataDomain: TimeDomain): boolean {
  return domain.start > dataDomain.start || domain.end < dataDomain.end;
}

/**
 * Wheel delta → zoom scale. A trackpad pinch arrives as a wheel event with
 * ctrlKey set and small deltas, a mouse wheel as larger line or pixel deltas,
 * so both are normalised to pixels and run through the same curve. Positive
 * deltaY (wheel down / pinch in) zooms out.
 */
export function wheelZoomScale(deltaY: number, deltaMode: number, pinch: boolean): number {
  if (!Number.isFinite(deltaY) || deltaY === 0) return 1;
  const px = deltaMode === 1 ? deltaY * 16 : deltaMode === 2 ? deltaY * 400 : deltaY;
  const clamped = Math.max(-200, Math.min(200, px));
  return Math.exp(-clamped * (pinch ? 0.01 : 0.0025));
}

/** The pixel position of `t` on a horizontal axis spanning `domain`. */
export function timeToX(t: number, domain: TimeDomain, left: number, width: number): number {
  const span = spanOf(domain) || 1;
  return left + ((t - domain.start) / span) * width;
}

/** The inverse of timeToX. */
export function xToTime(x: number, domain: TimeDomain, left: number, width: number): number {
  const w = width || 1;
  return domain.start + ((x - left) / w) * spanOf(domain);
}

/**
 * Index of the entry in ascending `times` nearest to `t` (ties go to the
 * earlier one). Binary search, so a page's worth of pointer moves over a
 * year of buckets stays cheap. Returns -1 for an empty array.
 */
export function nearestIndex(times: readonly number[], t: number): number {
  const n = times.length;
  if (!n) return -1;
  if (t <= times[0]) return 0;
  if (t >= times[n - 1]) return n - 1;
  let lo = 0;
  let hi = n - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (times[mid] <= t) lo = mid;
    else hi = mid;
  }
  return t - times[lo] <= times[hi] - t ? lo : hi;
}

/**
 * The [from, to) index range of buckets that overlap `domain` — a bucket
 * counts when any part of it (start through start + bucketMs) is inside.
 */
export function visibleRange(times: readonly number[], bucketMs: number, domain: TimeDomain): [number, number] {
  const n = times.length;
  if (!n) return [0, 0];
  let from = 0;
  while (from < n && times[from] + bucketMs <= domain.start) from++;
  let to = n;
  while (to > from && times[to - 1] >= domain.end) to--;
  return [from, to];
}

/** The index `steps` buckets away from `from`, clamped to the series. */
export function stepIndex(from: number | null, steps: number, count: number): number {
  if (!count) return -1;
  const base = from == null ? (steps < 0 ? count : -1) : from;
  return Math.max(0, Math.min(count - 1, base + steps));
}
