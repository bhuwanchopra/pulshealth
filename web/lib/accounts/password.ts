// Password hashing for viewer accounts: scrypt from node:crypto, so no
// dependency. Encoded self-describing, `scrypt$N$r$p$<salt>$<hash>` (base64url),
// so a later parameter bump verifies old hashes with their own parameters and
// rewrites them on the next successful sign-in (`needsRehash`).
//
// N=2^15, r=8, p=1 is OWASP's floor for scrypt: about 32 MiB and a few tens of
// milliseconds per attempt, which is affordable for a sign-in and makes an
// offline guess at a stolen hash expensive. Failed attempts are rate limited
// before they get here (lib/accounts/ratelimit.ts).

import { randomBytes, scrypt as scryptCallback, timingSafeEqual, type ScryptOptions } from "node:crypto";

export const SCRYPT_PARAMS = { N: 2 ** 15, r: 8, p: 1 } as const;
const SALT_BYTES = 32;
const KEY_BYTES = 32;

/** Accepted password lengths, in characters. No composition rules (NIST 800-63B). */
export const PASSWORD_MIN_LENGTH = 10;
export const PASSWORD_MAX_LENGTH = 256;

function scrypt(password: string, salt: Buffer, keyLength: number, options: ScryptOptions): Promise<Buffer> {
  // scrypt needs 128·N·r bytes; Node's default ceiling (32 MiB) is exactly the
  // N=2^15, r=8 requirement and refuses it, so allow headroom.
  const maxmem = 256 * (options.N ?? 0) * (options.r ?? 0);
  return new Promise((resolve, reject) => {
    scryptCallback(password.normalize("NFKC"), salt, keyLength, { ...options, maxmem }, (err, key) => {
      if (err) reject(err);
      else resolve(key);
    });
  });
}

/** A new encoded hash of `password` with the current parameters. */
export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(SALT_BYTES);
  const { N, r, p } = SCRYPT_PARAMS;
  const key = await scrypt(password, salt, KEY_BYTES, { N, r, p });
  return ["scrypt", N, r, p, salt.toString("base64url"), key.toString("base64url")].join("$");
}

interface Decoded {
  N: number;
  r: number;
  p: number;
  salt: Buffer;
  key: Buffer;
}

function decode(encoded: string): Decoded | null {
  const parts = encoded.split("$");
  if (parts.length !== 6 || parts[0] !== "scrypt") return null;
  const [N, r, p] = parts.slice(1, 4).map((v) => (/^\d{1,10}$/.test(v) ? Number(v) : NaN));
  // Bounds keep a corrupted or hostile row from asking for gigabytes.
  if (!Number.isInteger(N) || N < 2 || N > 2 ** 20 || (N & (N - 1)) !== 0) return null;
  if (!Number.isInteger(r) || r < 1 || r > 32) return null;
  if (!Number.isInteger(p) || p < 1 || p > 16) return null;
  const salt = Buffer.from(parts[4], "base64url");
  const key = Buffer.from(parts[5], "base64url");
  if (salt.length < 16 || key.length < 16 || key.length > 64) return null;
  return { N, r, p, salt, key };
}

/**
 * Whether `password` matches `encoded`. Constant-time in the comparison; a
 * malformed hash is simply a mismatch.
 */
export async function verifyPassword(password: string, encoded: string): Promise<boolean> {
  const decoded = decode(encoded);
  if (!decoded) return false;
  const { N, r, p, salt, key } = decoded;
  const candidate = await scrypt(password, salt, key.length, { N, r, p });
  return timingSafeEqual(candidate, key);
}

/** Whether `encoded` was made with parameters other than the current ones. */
export function needsRehash(encoded: string): boolean {
  const decoded = decode(encoded);
  if (!decoded) return true;
  const { N, r, p } = SCRYPT_PARAMS;
  return decoded.N !== N || decoded.r !== r || decoded.p !== p || decoded.key.length !== KEY_BYTES;
}

// A real hash of a random secret, made once: a sign-in for an email with no
// account verifies against it, so "no such account" takes as long as "wrong
// password" and the response time does not reveal which addresses exist.
let decoy: Promise<string> | null = null;
export async function burnPasswordCheck(password: string): Promise<void> {
  decoy ??= hashPassword(randomBytes(24).toString("base64url"));
  await verifyPassword(password, await decoy);
}

export type NewPasswordProblem = "mismatch" | "short" | "long";

/** Why a new password is refused, or null when it is acceptable. */
export function newPasswordProblem(password: string, confirmation: string): NewPasswordProblem | null {
  if (password !== confirmation) return "mismatch";
  const length = [...password].length;
  if (length < PASSWORD_MIN_LENGTH) return "short";
  if (length > PASSWORD_MAX_LENGTH) return "long";
  return null;
}
