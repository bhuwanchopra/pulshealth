import { describe, expect, it } from "vitest";
import {
  clampDomain,
  dataDomainOf,
  isZoomed,
  minimumSpan,
  MIN_VISIBLE_POINTS,
  nearestIndex,
  panDomain,
  stepIndex,
  timeToX,
  visibleRange,
  wheelZoomScale,
  xToTime,
  zoomDomain,
} from "./chartDomain";

const DAY = 86_400_000;
// Thirty daily buckets: the Month range.
const times = Array.from({ length: 30 }, (_, i) => i * DAY);
const data = dataDomainOf(times, DAY)!;
const minSpan = minimumSpan(data, DAY, times.length);

describe("data domain", () => {
  it("runs from the first bucket start to the end of the last bucket", () => {
    expect(data).toEqual({ start: 0, end: 30 * DAY });
    expect(dataDomainOf([], DAY)).toBeNull();
  });

  it("never narrows below MIN_VISIBLE_POINTS buckets, or the whole series when shorter", () => {
    expect(minSpan).toBe(MIN_VISIBLE_POINTS * DAY);
    expect(minimumSpan(dataDomainOf([0, DAY, 2 * DAY], DAY)!, DAY, 3)).toBe(3 * DAY);
  });
});

describe("clampDomain", () => {
  it("leaves a window inside the data alone", () => {
    expect(clampDomain({ start: 5 * DAY, end: 15 * DAY }, data, minSpan)).toEqual({ start: 5 * DAY, end: 15 * DAY });
  });

  it("slides a window back inside the data instead of shrinking it", () => {
    expect(clampDomain({ start: -3 * DAY, end: 7 * DAY }, data, minSpan)).toEqual({ start: 0, end: 10 * DAY });
    expect(clampDomain({ start: 25 * DAY, end: 35 * DAY }, data, minSpan)).toEqual({ start: 20 * DAY, end: 30 * DAY });
  });

  it("widens a window narrower than the minimum span", () => {
    const d = clampDomain({ start: 10 * DAY, end: 11 * DAY }, data, minSpan);
    expect(d.end - d.start).toBe(minSpan);
    expect(d.start).toBe(10 * DAY);
  });

  it("caps a window wider than the data at the data", () => {
    expect(clampDomain({ start: -DAY, end: 40 * DAY }, data, minSpan)).toEqual(data);
  });

  it("never produces start >= end or a window outside the data", () => {
    const d = clampDomain({ start: 12 * DAY, end: 12 * DAY }, data, minSpan);
    expect(d.start).toBeLessThan(d.end);
    expect(d.start).toBeGreaterThanOrEqual(data.start);
    expect(d.end).toBeLessThanOrEqual(data.end);
  });
});

describe("zoomDomain", () => {
  it("zooms in, keeping the point under the pointer fixed", () => {
    const center = 10 * DAY; // a third of the way in
    const d = zoomDomain(data, center, 2, data, minSpan);
    expect(d.end - d.start).toBe(15 * DAY);
    // the pointer's relative position is unchanged
    expect((center - d.start) / (d.end - d.start)).toBeCloseTo(1 / 3, 9);
  });

  it("zooms out around the pointer and stops at the full data", () => {
    const zoomed = { start: 10 * DAY, end: 20 * DAY };
    const d = zoomDomain(zoomed, 15 * DAY, 0.5, data, minSpan);
    expect(d).toEqual({ start: 5 * DAY, end: 25 * DAY });
    expect(zoomDomain(d, 15 * DAY, 0.1, data, minSpan)).toEqual(data);
  });

  it("stops at the minimum span", () => {
    const d = zoomDomain(data, 15 * DAY, 100, data, minSpan);
    expect(d.end - d.start).toBe(minSpan);
    expect(d.start).toBeGreaterThanOrEqual(data.start);
    expect(d.end).toBeLessThanOrEqual(data.end);
  });

  it("is anchored at the edges without leaving the data", () => {
    const d = zoomDomain(data, data.end, 3, data, minSpan);
    expect(d).toEqual({ start: 20 * DAY, end: 30 * DAY });
  });

  it("ignores a nonsense scale", () => {
    expect(zoomDomain(data, 5 * DAY, 0, data, minSpan)).toEqual(data);
    expect(zoomDomain(data, 5 * DAY, Number.NaN, data, minSpan)).toEqual(data);
  });
});

describe("panDomain", () => {
  const zoomed = { start: 10 * DAY, end: 20 * DAY };

  it("pans left and right by the delta", () => {
    expect(panDomain(zoomed, -3 * DAY, data)).toEqual({ start: 7 * DAY, end: 17 * DAY });
    expect(panDomain(zoomed, 3 * DAY, data)).toEqual({ start: 13 * DAY, end: 23 * DAY });
  });

  it("stops at the edges of the data, keeping its width", () => {
    expect(panDomain(zoomed, -50 * DAY, data)).toEqual({ start: 0, end: 10 * DAY });
    expect(panDomain(zoomed, 50 * DAY, data)).toEqual({ start: 20 * DAY, end: 30 * DAY });
  });

  it("cannot move a window that already shows everything", () => {
    expect(panDomain(data, 5 * DAY, data)).toEqual(data);
    expect(panDomain(data, -5 * DAY, data)).toEqual(data);
  });

  it("is a no-op for a zero delta", () => {
    expect(panDomain(zoomed, 0, data)).toBe(zoomed);
  });
});

describe("isZoomed", () => {
  it("is false for the full data and true for any narrower window", () => {
    expect(isZoomed(data, data)).toBe(false);
    expect(isZoomed({ start: DAY, end: data.end }, data)).toBe(true);
    expect(isZoomed({ start: 0, end: data.end - DAY }, data)).toBe(true);
  });
});

describe("wheelZoomScale", () => {
  it("zooms in on wheel up and out on wheel down", () => {
    expect(wheelZoomScale(-100, 0, false)).toBeGreaterThan(1);
    expect(wheelZoomScale(100, 0, false)).toBeLessThan(1);
    expect(wheelZoomScale(0, 0, false)).toBe(1);
  });

  it("normalises line and page deltas to pixels", () => {
    expect(wheelZoomScale(-3, 1, false)).toBeCloseTo(wheelZoomScale(-48, 0, false), 9);
    expect(wheelZoomScale(-1, 2, false)).toBe(wheelZoomScale(-400, 0, false));
  });

  it("treats a trackpad pinch (ctrlKey) as a steeper, bounded curve", () => {
    expect(wheelZoomScale(-10, 0, true)).toBeGreaterThan(wheelZoomScale(-10, 0, false));
    expect(wheelZoomScale(-10_000, 0, true)).toBe(wheelZoomScale(-200, 0, true));
  });
});

describe("pixel mapping", () => {
  it("round-trips through timeToX and xToTime", () => {
    const d = { start: 10 * DAY, end: 20 * DAY };
    const t = 12.5 * DAY;
    const x = timeToX(t, d, 46, 600);
    expect(x).toBeCloseTo(46 + 150, 9);
    expect(xToTime(x, d, 46, 600)).toBeCloseTo(t, 6);
  });
});

describe("nearestIndex", () => {
  it("finds the nearest bucket, clamping outside the series", () => {
    expect(nearestIndex(times, -DAY)).toBe(0);
    expect(nearestIndex(times, 1000 * DAY)).toBe(29);
    expect(nearestIndex(times, 10.4 * DAY)).toBe(10);
    expect(nearestIndex(times, 10.6 * DAY)).toBe(11);
    expect(nearestIndex(times, 10.5 * DAY)).toBe(10); // ties go earlier
    expect(nearestIndex([], 0)).toBe(-1);
  });
});

describe("visibleRange", () => {
  it("includes every bucket that overlaps the window", () => {
    expect(visibleRange(times, DAY, data)).toEqual([0, 30]);
    expect(visibleRange(times, DAY, { start: 10 * DAY, end: 20 * DAY })).toEqual([10, 20]);
    // a window starting mid-bucket keeps that bucket
    expect(visibleRange(times, DAY, { start: 10.5 * DAY, end: 19.5 * DAY })).toEqual([10, 20]);
    expect(visibleRange([], DAY, data)).toEqual([0, 0]);
  });
});

describe("stepIndex", () => {
  it("moves by steps within the series and enters from either end", () => {
    expect(stepIndex(10, 1, 30)).toBe(11);
    expect(stepIndex(10, -1, 30)).toBe(9);
    expect(stepIndex(29, 1, 30)).toBe(29);
    expect(stepIndex(0, -1, 30)).toBe(0);
    expect(stepIndex(null, 1, 30)).toBe(0);
    expect(stepIndex(null, -1, 30)).toBe(29);
    expect(stepIndex(null, 1, 0)).toBe(-1);
  });
});
