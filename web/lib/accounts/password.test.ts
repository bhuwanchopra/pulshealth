import { describe, expect, it } from "vitest";

import {
  hashPassword,
  needsRehash,
  newPasswordProblem,
  PASSWORD_MIN_LENGTH,
  SCRYPT_PARAMS,
  verifyPassword,
} from "./password";

describe("password hashing", () => {
  it("encodes scrypt with its parameters and a fresh salt", async () => {
    const a = await hashPassword("correct horse battery");
    const b = await hashPassword("correct horse battery");
    const [scheme, N, r, p, salt, key] = a.split("$");
    expect(scheme).toBe("scrypt");
    expect([Number(N), Number(r), Number(p)]).toEqual([SCRYPT_PARAMS.N, SCRYPT_PARAMS.r, SCRYPT_PARAMS.p]);
    expect(Buffer.from(salt, "base64url")).toHaveLength(32);
    expect(Buffer.from(key, "base64url")).toHaveLength(32);
    expect(a).not.toBe(b); // salted
  });

  it("verifies the right password and nothing else", async () => {
    const hash = await hashPassword("correct horse battery");
    expect(await verifyPassword("correct horse battery", hash)).toBe(true);
    expect(await verifyPassword("correct horse batterY", hash)).toBe(false);
    expect(await verifyPassword("", hash)).toBe(false);
  });

  it("treats a compatibility-equivalent spelling as the same password (NFKC)", async () => {
    const hash = await hashPassword("ﬁsh and chips!"); // U+FB01 ligature
    expect(await verifyPassword("fish and chips!", hash)).toBe(true);
  });

  it("verifies an older hash with its own parameters, and asks for a rehash", async () => {
    // As if made under weaker parameters: N=2^14.
    const { scryptSync, randomBytes } = await import("node:crypto");
    const salt = randomBytes(32);
    const key = scryptSync("old password!", salt, 32, { N: 2 ** 14, r: 8, p: 1 });
    const old = ["scrypt", 2 ** 14, 8, 1, salt.toString("base64url"), key.toString("base64url")].join("$");
    expect(await verifyPassword("old password!", old)).toBe(true);
    expect(needsRehash(old)).toBe(true);
    expect(needsRehash(await hashPassword("new password!"))).toBe(false);
  });

  it("rejects malformed or hostile encodings instead of trying them", async () => {
    for (const bad of [
      "",
      "plain",
      "scrypt$32768$8$1$c2FsdA",
      "bcrypt$32768$8$1$c2FsdHNhbHRzYWx0c2FsdA$a2V5a2V5a2V5a2V5a2V5",
      // N not a power of two / absurdly large / r out of range
      "scrypt$1000$8$1$c2FsdHNhbHRzYWx0c2FsdA$a2V5a2V5a2V5a2V5a2V5",
      "scrypt$1073741824$8$1$c2FsdHNhbHRzYWx0c2FsdA$a2V5a2V5a2V5a2V5a2V5",
      "scrypt$32768$999$1$c2FsdHNhbHRzYWx0c2FsdA$a2V5a2V5a2V5a2V5a2V5",
    ]) {
      expect(await verifyPassword("anything at all", bad), bad).toBe(false);
      expect(needsRehash(bad), bad).toBe(true);
    }
  });

  it("states what is wrong with a new password", () => {
    const ok = "a".repeat(PASSWORD_MIN_LENGTH);
    expect(newPasswordProblem(ok, ok)).toBeNull();
    expect(newPasswordProblem(ok, `${ok}x`)).toBe("mismatch");
    expect(newPasswordProblem("short", "short")).toBe("short");
    expect(newPasswordProblem("x".repeat(300), "x".repeat(300))).toBe("long");
    // Counted in characters, not UTF-16 units.
    const emoji = "🙂".repeat(PASSWORD_MIN_LENGTH);
    expect(newPasswordProblem(emoji, emoji)).toBeNull();
  });
});
