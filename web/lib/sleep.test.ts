import { describe, expect, it } from "vitest";
import { calculateSleepScore, sleepScoreClassification, type SleepDay } from "./sleep";

function night(overrides: Partial<SleepDay> = {}): SleepDay {
  return {
    date: "2026-09-28",
    asleepMinutes: 480,
    inBedMinutes: 500,
    coreMinutes: 240,
    deepMinutes: 100,
    remMinutes: 140,
    unspecifiedMinutes: 0,
    awakeMinutes: 20,
    bedtimeMinutes: 1380,
    awakePeriods: 1,
    nights: 1,
    ...overrides,
  };
}

describe("sleep score", () => {
  it("gives a full score to an ideal night with a consistent bedtime", () => {
    const score = calculateSleepScore(
      night({ awakeMinutes: 0 }),
      [night({ awakeMinutes: 0 }), night({ date: "2026-09-27" })],
    );

    expect(score.score).toBe(100);
    expect(score.durationPoints).toBe(50);
    expect(score.consistencyPoints).toBe(30);
    expect(score.interruptionPoints).toBe(20);
  });

  it("uses circular bedtime distance across midnight", () => {
    const score = calculateSleepScore(
      night({ bedtimeMinutes: 10 }),
      [night({ date: "2026-09-27", bedtimeMinutes: 1430 })],
    );

    expect(score.bedtimeDeviationMinutes).toBe(20);
    expect(score.consistencyPoints).toBe(25);
  });

  it("penalizes both long awake time and repeated awakenings", () => {
    const score = calculateSleepScore(
      night({ awakeMinutes: 120, awakePeriods: 6 }),
      [night()],
    );

    expect(score.interruptionPoints).toBe(0);
    expect(score.score).toBe(80);
  });

  it("falls back to no consistency penalty when no bedtime history exists", () => {
    const score = calculateSleepScore(
      night({ bedtimeMinutes: null }),
      [night({ bedtimeMinutes: null })],
    );

    expect(score.consistencyPoints).toBe(0);
    expect(score.baselineNights).toBe(0);
  });

  it("matches the documented classification boundaries", () => {
    expect(sleepScoreClassification(96)).toBe("Very High");
    expect(sleepScoreClassification(81)).toBe("High");
    expect(sleepScoreClassification(61)).toBe("OK");
    expect(sleepScoreClassification(41)).toBe("Low");
    expect(sleepScoreClassification(40)).toBe("Very Low");
  });
});
