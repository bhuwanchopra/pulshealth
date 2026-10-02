import { describe, expect, it } from "vitest";
import { defaultAgg, isCumulative, RANGES } from "./metrics";

describe("metric semantics", () => {
  it("sums cumulative types and averages discrete ones", () => {
    expect(defaultAgg("HKQuantityTypeIdentifierStepCount")).toBe("sum");
    expect(defaultAgg("HKQuantityTypeIdentifierHeartRate")).toBe("avg");
  });

  it("treats UV exposure as a discrete index reading, not a daily total", () => {
    // HKQuantityTypeIdentifierUVExposure has a discrete aggregation style on
    // device; summing readings per day produced meaningless "Today" totals.
    expect(isCumulative("HKQuantityTypeIdentifierUVExposure")).toBe(false);
    expect(isCumulative("HKQuantityTypeIdentifierTimeInDaylight")).toBe(true);
  });

  it("keeps daily resolution for long ranges so charts can zoom to individual days", () => {
    expect(RANGES["6M"].bucket).toBe("1 day");
    expect(RANGES["6M"].bucketMs).toBe(86_400_000);
    expect(RANGES.Y.bucket).toBe("1 day");
    expect(RANGES.Y.bucketMs).toBe(86_400_000);
  });
});
