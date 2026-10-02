import { describe, expect, it } from "vitest";
import { clampDomain, panDomain, zoomDomain } from "./chart";

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
