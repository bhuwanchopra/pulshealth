import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";

import { newInviteToken, normalizeEmail, parseArgs } from "../scripts/invite.mjs";

const USER = "11111111-1111-4111-8111-111111111111";

describe("scripts/invite.mjs", () => {
  it("parses a complete invite", () => {
    expect(parseArgs(["--user", USER.toUpperCase(), "--email", " Ann@Example.com ", "--admin"], {})).toEqual({
      options: { user: USER, email: "ann@example.com", admin: true, url: null, hours: 48 },
    });
  });

  it("takes the base URL from WEB_PUBLIC_URL unless --url says otherwise", () => {
    expect(parseArgs(["--user", USER, "--email", "a@example.com"], { WEB_PUBLIC_URL: "https://viewer.example/x" }).options?.url)
      .toBe("https://viewer.example");
    expect(
      parseArgs(["--user", USER, "--email", "a@example.com", "--url", "https://other.example"], { WEB_PUBLIC_URL: "https://viewer.example" })
        .options?.url,
    ).toBe("https://other.example");
  });

  it("refuses what would make a broken or unsafe link", () => {
    expect(parseArgs([], {}).error).toMatch(/--user/);
    expect(parseArgs(["--user", "nope", "--email", "a@example.com"], {}).error).toMatch(/--user/);
    expect(parseArgs(["--user", USER, "--email", "not-an-email"], {}).error).toMatch(/--email/);
    expect(parseArgs(["--user", USER, "--email", "a@example.com", "--url", "http://viewer.example"], {}).error).toMatch(/https/);
    expect(parseArgs(["--user", USER, "--email", "a@example.com", "--hours", "0"], {}).error).toMatch(/--hours/);
    expect(parseArgs(["--user", USER, "--email"], {}).error).toMatch(/needs a value/);
    expect(parseArgs(["--bogus"], {}).error).toMatch(/unknown/);
  });

  it("normalises email the way the viewer does", () => {
    expect(normalizeEmail("  A@B.co ")).toBe("a@b.co");
    expect(normalizeEmail("a b@c")).toBeNull();
  });

  it("stores the SHA-256 of the token's bytes, the same as the viewer looks up", () => {
    const { token, hash } = newInviteToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(hash.equals(createHash("sha256").update(Buffer.from(token, "base64url")).digest())).toBe(true);
  });
});
