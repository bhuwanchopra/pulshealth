// What the accounts pages say for each `?error=` / `?notice=` code the
// handlers redirect with. Codes, not prose, travel in the URL, so a link
// cannot be made to show arbitrary text.

import { PASSWORD_MAX_LENGTH, PASSWORD_MIN_LENGTH } from "./password";

const ERRORS: Record<string, string> = {
  invalid: "That email and password do not match an account.",
  throttled: "Too many attempts. Wait a minute, then try again.",
  unavailable: "Something went wrong on the server. Try again in a moment.",
  invite: "That invite link is not valid. Ask for a new one.",
  mismatch: "The two passwords do not match.",
  short: `Use at least ${PASSWORD_MIN_LENGTH} characters.`,
  long: `Use at most ${PASSWORD_MAX_LENGTH} characters.`,
  current: "Your current password was not right.",
  email_taken: "Another account already uses this email address. Ask for a new invite.",
};

const NOTICES: Record<string, string> = {
  "signed-out": "You are signed out.",
  password: "Password changed. Every other browser signed in to this account has been signed out.",
  sessions: "Signed out.",
};

/** One query parameter as a single string (Next.js hands over string | string[]). */
export function param(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export function errorMessage(code: string | undefined, overrides: Record<string, string> = {}): string | null {
  if (!code) return null;
  return overrides[code] ?? ERRORS[code] ?? null;
}

export function noticeMessage(code: string | undefined): string | null {
  return code ? (NOTICES[code] ?? null) : null;
}
