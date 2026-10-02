import { describe, expect, it, vi } from "vitest";

vi.mock("../db", () => ({ query: vi.fn(), transaction: vi.fn() }));

describe("session tokens and cookie", async () => {
  const { newToken, SESSION_COOKIE, sessionCookieAttributes, tokenHash } = await import("./session");

  it("makes 256-bit tokens and stores only their SHA-256", () => {
    const token = newToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(token, "base64url")).toHaveLength(32);
    const hash = tokenHash(token);
    expect(hash).toHaveLength(32);
    expect(hash!.equals(Buffer.from(token, "base64url"))).toBe(false);
    expect(tokenHash(token)!.equals(hash!)).toBe(true);
    expect(newToken()).not.toBe(token);
  });

  it("never sends junk to the database", () => {
    for (const bad of [undefined, null, "", "short", `${newToken()}x`, "a".repeat(42) + "!"]) {
      expect(tokenHash(bad)).toBeNull();
    }
  });

  it("is a __Host- cookie: Secure, HttpOnly, SameSite=Lax, Path=/, 30 days", () => {
    expect(SESSION_COOKIE.startsWith("__Host-")).toBe(true);
    expect(sessionCookieAttributes()).toEqual({
      httpOnly: true,
      secure: true,
      sameSite: "lax",
      path: "/",
      maxAge: 30 * 86_400,
    });
    expect(sessionCookieAttributes(0).maxAge).toBe(0);
  });
});
