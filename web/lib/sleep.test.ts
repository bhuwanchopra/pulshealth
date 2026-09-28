import { describe, expect, it } from "vitest";
import { calculateSleepScore, calculateSleepScores, sleepScoreClassification, type SleepDay } from "./sleep";

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

  it("scores historical nights only against preceding nights", () => {
    const nights = [
      night({ date: "2026-09-26", bedtimeMinutes: 1380 }),
      night({ date: "2026-09-27", bedtimeMinutes: 1380 }),
      night({ date: "2026-09-28", bedtimeMinutes: 10 }),
    ];

    const scored = calculateSleepScores(nights);

    expect(scored).toHaveLength(3);
    expect(scored[0].score.baselineNights).toBe(0);
    expect(scored[1].score.baselineNights).toBe(1);
    expect(scored[2].score.baselineNights).toBe(2);
    expect(scored[2].score.bedtimeDeviationMinutes).toBe(70);
  });

  it("uses at most the preceding 13 nights for consistency", () => {
    const nights = Array.from({ length: 15 }, (_, index) =>
      night({
        date: `2026-09-${String(14 + index).padStart(2, "0")}`,
        bedtimeMinutes: 1380,
      }),
    );
    const scored = calculateSleepScores(nights);

    expect(scored[13].score.baselineNights).toBe(13);
    expect(scored[14].score.baselineNights).toBe(13);
  });

  it("matches the documented classification boundaries", () => {
    expect(sleepScoreClassification(96)).toBe("Very High");
    expect(sleepScoreClassification(81)).toBe("High");
    expect(sleepScoreClassification(61)).toBe("OK");
    expect(sleepScoreClassification(41)).toBe("Low");
    expect(sleepScoreClassification(40)).toBe("Very Low");
  });
});
