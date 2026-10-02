// Which user the viewer shows for this request (SRV-11).
//
// In accounts mode (WEB_ACCOUNTS=true, lib/mode.ts) the answer is the
// signed-in session's user and nothing else: the session cookie is looked up
// in the database on every request (once per request, cached), and the
// `puls-user` cookie and `?user=` below are ignored. Everything that follows
// in this comment is Basic and open mode.
//
// The database can hold more than one person's records (every table carries a
// user_id), but the viewer used to render exactly one: PULS_USER_ID. The
// chosen user now lives in a cookie, set by POST /api/user (the sidebar's
// switcher) or by `?user=<uuid>` on any page (proxy.ts). It is a preference,
// not access control — everyone behind the one WEB_AUTH_PASSWORD can pick any
// user — so the cookie carries nothing that needs signing: a forged value is
// at worst a UUID the database does not have, which renders empty.
//
// `cookies()` needs a request scope, so this module is imported by pages and
// route handlers only; lib/queries.ts takes the user id as a plain argument
// and stays testable without one.

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { cache } from "react";
import { findSession, SESSION_COOKIE, type Session } from "./accounts/session";
import { defaultUserId, UUID_RE } from "./config";
import { viewerMode } from "./mode";

/** Cookie holding the chosen user's id. */
export const USER_COOKIE = "puls-user";

/** Seconds the choice is remembered for: a year. */
export const USER_COOKIE_MAX_AGE = 31_536_000;

/**
 * The user a cookie value selects: the value when it is a UUID, otherwise the
 * fallback. Pure, so the tests can hit it without a request.
 */
export function parseViewerUser(cookieValue: string | undefined, fallback: string): string {
  if (cookieValue && UUID_RE.test(cookieValue)) return cookieValue.toLowerCase();
  return fallback;
}

/**
 * Where to send the browser after a choice or a sign-in: `value` when it is a
 * same-origin path, otherwise `/`. Anything with a scheme or host
 * (`https://…`, `//…`, `\\…`) is refused so a `next` field cannot be pointed
 * off-site — and so is any control character or backslash, because browsers
 * strip tabs and newlines from a URL before parsing it: `/<TAB>/evil.example`
 * would otherwise arrive as `//evil.example`.
 */
export function safeReturnPath(value: string | null | undefined): string {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return "/";
  if (/[\u0000-\u001f\u007f\\]/.test(value)) return "/";
  const base = "http://viewer.invalid";
  try {
    const url = new URL(value, base);
    const path = `${url.pathname}${url.search}${url.hash}`;
    // Parsing resolves dot segments, and `/.//evil.example` comes out as
    // `//evil.example` — another site. Check what comes out, not just what
    // went in.
    if (url.origin !== base || path.startsWith("//") || path.includes("\\")) return "/";
    return path;
  } catch {
    return "/";
  }
}

/** Cookie attributes for the chosen user; `Secure` only where the page is. */
export function userCookieOptions(secure: boolean) {
  return {
    path: "/",
    httpOnly: true,
    sameSite: "lax" as const,
    maxAge: USER_COOKIE_MAX_AGE,
    secure,
  };
}

/**
 * The signed-in session for this request, or null — always null outside
 * accounts mode. Read-only (proxy.ts slides the expiry); cached per request.
 */
export const currentSession = cache(async (): Promise<Session | null> => {
  if (viewerMode() !== "accounts") return null;
  const jar = await cookies();
  return findSession(jar.get(SESSION_COOKIE)?.value);
});

/**
 * The user this request shows. Accounts mode: the session's user, or a
 * redirect to sign in. Otherwise: the cookie's choice, else PULS_USER_ID.
 */
export async function viewerUser(): Promise<string> {
  if (viewerMode() === "accounts") {
    const session = await currentSession();
    if (!session) redirect("/login");
    return session.userId;
  }
  const jar = await cookies();
  return parseViewerUser(jar.get(USER_COOKIE)?.value, defaultUserId());
}
