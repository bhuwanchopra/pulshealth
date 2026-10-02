import { describe, expect, it } from "vitest";
import {
  clampDomain,
  niceStep,
  niceTicks,
  panDomain,
  zoomDomain,
} from "./chart";

describe("chart interaction domains", () => {
  it("clamps domains to the data bounds", () => {
    expect(clampDomain([-10, 30], 0, 100)).toEqual([0, 40]);
    expect(clampDomain([80, 140], 0, 100)).toEqual([40, 100]);
  });

  it("zooms around the gesture center", () => {
    expect(zoomDomain([0, 100], 50, 2, 0, 100, 3)).toEqual([25, 75]);
    expect(zoomDomain([0, 100], 25, 2, 0, 100, 3)).toEqual([12.5, 62.5]);
  });

  it("does not zoom beyond the minimum span or data bounds", () => {
    expect(zoomDomain([0, 10], 5, 100, 0, 10, 3)).toEqual([3.5, 6.5]);
    expect(zoomDomain([0, 10], 0, 2, 0, 10, 3)).toEqual([0, 5]);
  });

  it("pans without crossing either boundary", () => {
    expect(panDomain([20, 50], -100, 0, 100)).toEqual([0, 30]);
    expect(panDomain([20, 50], 100, 0, 100)).toEqual([70, 100]);
    expect(panDomain([0, 100], 20, 0, 100)).toEqual([0, 100]);
  });
});

describe("niceStep", () => {
  it("rounds up to a 1/2/5 step with the decimals it needs", () => {
    expect(niceStep(2.03)).toEqual({ step: 5, decimals: 0 });
    expect(niceStep(1.5)).toEqual({ step: 2, decimals: 0 });
    expect(niceStep(32.5)).toEqual({ step: 50, decimals: 0 });
    expect(niceStep(0.0035)).toEqual({ step: 0.005, decimals: 3 });
    expect(niceStep(0.07)).toEqual({ step: 0.1, decimals: 1 });
  });

  it("keeps an exact step", () => {
    expect(niceStep(2)).toEqual({ step: 2, decimals: 0 });
    expect(niceStep(0.02)).toEqual({ step: 0.02, decimals: 2 });
  });
});

describe("niceTicks", () => {
  it("labels fractional per-sample values instead of rounding them to 0", () => {
    // A resting-energy stream: a few hundredths of a kcal per sample.
    const { lo, hi, ticks } = niceTicks(0.012, 0.094);
    expect(ticks.map((t) => t.label)).toEqual([
      "0.00",
      "0.02",
      "0.04",
      "0.06",
      "0.08",
      "0.10",
    ]);
    expect(lo).toBe(0);
    expect(hi).toBeCloseTo(0.1);
    expect(new Set(ticks.map((t) => t.label)).size).toBe(ticks.length);
  });

  it("gives heart rate whole, evenly spaced labels", () => {
    const { lo, hi, ticks } = niceTicks(62, 188);
    expect(ticks.map((t) => t.label)).toEqual(["50", "100", "150", "200"]);
    expect([lo, hi]).toEqual([50, 200]);
  });

  it("covers the data", () => {
    for (const [min, max] of [
      [0.3, 4.1],
      [-12, 7],
      [998, 1003],
      [0.0004, 0.0031],
    ]) {
      const { lo, hi } = niceTicks(min, max);
      expect(lo).toBeLessThanOrEqual(min);
      expect(hi).toBeGreaterThanOrEqual(max);
    }
  });

  it("pads a flat series", () => {
    const { lo, hi, ticks } = niceTicks(5, 5);
    expect(lo).toBeLessThan(5);
    expect(hi).toBeGreaterThan(5);
    expect(ticks.length).toBeGreaterThan(1);
  });
});
