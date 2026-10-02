import { describe, expect, it } from "vitest";

import { AUTH_FAILURE_BURST, checkAll, failAll, failureKeys, FailureLimiter, refundAll, takeAll } from "./ratelimit";

describe("FailureLimiter", () => {
  it("allows unknown keys without remembering them", () => {
    const limiter = new FailureLimiter();
    expect(limiter.check("ip:1.2.3.4", 0)).toEqual({ allowed: true });
    expect(limiter.size).toBe(0);
  });

  it("refuses once the burst of failures is spent, before anything is checked", () => {
    const limiter = new FailureLimiter();
    for (let i = 0; i < AUTH_FAILURE_BURST; i++) {
      expect(limiter.check("k", 0).allowed).toBe(true);
      limiter.fail("k", 0);
    }
    const refused = limiter.check("k", 0);
    expect(refused.allowed).toBe(false);
    if (!refused.allowed) expect(refused.retryAfterSeconds).toBeGreaterThanOrEqual(6);
  });

  it("refills continuously at the per-minute rate", () => {
    const limiter = new FailureLimiter(10, 10);
    for (let i = 0; i < 10; i++) limiter.fail("k", 0);
    expect(limiter.check("k", 0).allowed).toBe(false);
    expect(limiter.check("k", 5_999).allowed).toBe(false);
    expect(limiter.check("k", 6_000).allowed).toBe(true); // 10/min → one per 6 s
  });

  it("never charges successes: only fail() spends tokens", () => {
    const limiter = new FailureLimiter();
    for (let i = 0; i < 1000; i++) limiter.check("k", i);
    expect(limiter.size).toBe(0);
  });

  it("forgets idle, refilled buckets and caps the table", () => {
    const limiter = new FailureLimiter(10, 10, 60_000, 8);
    for (let i = 0; i < 8; i++) limiter.fail(`k${i}`, 0);
    expect(limiter.size).toBe(8);
    // At the cap, the oldest quarter goes first.
    limiter.fail("new", 1);
    expect(limiter.size).toBeLessThanOrEqual(7);
    // Long idle and full again: swept on the next new key.
    limiter.fail("later", 10 * 60_000);
    expect(limiter.size).toBe(1);
  });

  it("charges an address and an email together, and either one exhausted refuses", () => {
    const limiter = new FailureLimiter();
    const keys = failureKeys("203.0.113.9", "a@example.com");
    expect(keys).toEqual(["ip:203.0.113.9", "email:a@example.com"]);
    // Many addresses guessing at one email: the email bucket stops them.
    for (let i = 0; i < AUTH_FAILURE_BURST; i++) failAll(limiter, failureKeys(`198.51.100.${i}`, "a@example.com"), 0);
    expect(checkAll(limiter, failureKeys("192.0.2.1", "a@example.com"), 0).allowed).toBe(false);
    expect(checkAll(limiter, failureKeys("192.0.2.1", "b@example.com"), 0).allowed).toBe(true);
  });

  it("takes the token before the check is awaited, so a parallel burst cannot outrun it", async () => {
    const limiter = new FailureLimiter();
    const keys = failureKeys("198.51.100.1", "a@example.com");
    // Fifty attempts that all start before any finishes, as concurrent
    // requests do: each takes its token synchronously, then "verifies".
    const verify = () => new Promise((resolve) => setTimeout(resolve, 5));
    const results = await Promise.all(
      Array.from({ length: 50 }, async () => {
        if (!takeAll(limiter, keys, 0).allowed) return "throttled";
        await verify();
        return "checked";
      }),
    );
    expect(results.filter((r) => r === "checked")).toHaveLength(AUTH_FAILURE_BURST);
  });

  it("gives the token back for an attempt that did not fail", () => {
    const limiter = new FailureLimiter();
    const keys = ["ip:198.51.100.2"];
    for (let i = 0; i < 100; i++) {
      expect(takeAll(limiter, keys, 0).allowed).toBe(true);
      refundAll(limiter, keys, 0); // a success
    }
    for (let i = 0; i < AUTH_FAILURE_BURST; i++) expect(takeAll(limiter, keys, 0).allowed).toBe(true);
    expect(takeAll(limiter, keys, 0).allowed).toBe(false);
    // A refund never fills a bucket past its burst.
    for (let i = 0; i < 50; i++) refundAll(limiter, keys, 0);
    for (let i = 0; i < AUTH_FAILURE_BURST; i++) takeAll(limiter, keys, 0);
    expect(takeAll(limiter, keys, 0).allowed).toBe(false);
  });
});
