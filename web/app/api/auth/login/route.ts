import type { NextRequest } from "next/server";

import { accountsOnly, field, readForm, requestIp, seeOther, setSessionCookie } from "@/lib/accounts/http";
import { burnPasswordCheck, hashPassword, needsRehash, PASSWORD_MAX_LENGTH, verifyPassword } from "@/lib/accounts/password";
import { authFailures, failureKeys, refundAll, takeAll } from "@/lib/accounts/ratelimit";
import { createSession, deleteSession, SESSION_COOKIE, tokenHash } from "@/lib/accounts/session";
import { findAccountForLogin, normalizeEmail, replacePasswordHash } from "@/lib/accounts/store";
import { safeReturnPath } from "@/lib/viewer";

// The sign-in form posts here (accounts mode). proxy.ts has already refused
// plain HTTP and cross-site posts. Every outcome is a 303: back to /login
// with an error code, or on to `next` with a new session cookie.
//
// Each attempt takes a token from the client address's bucket and the
// email's before anything is looked up, and gets it back only if it
// succeeds (lib/accounts/ratelimit.ts) — so only failures cost, an exhausted
// bucket is refused before the password is looked at, and parallel guesses
// cannot all slip past the check while the first is still being verified.
// An unknown email costs the same scrypt as a known one, so timing does not
// reveal which addresses have accounts, and the error never says which half
// was wrong. Nothing about a failed attempt is logged.
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const off = accountsOnly();
  if (off) return off;

  const form = await readForm(request);
  const next = safeReturnPath(field(form, "next"));
  const back = (error: string) =>
    seeOther(`/login?error=${error}${next === "/" ? "" : `&next=${encodeURIComponent(next)}`}`);

  const email = normalizeEmail(field(form, "email"));
  const password = field(form, "password");
  const keys = failureKeys(requestIp(request), email ?? undefined);
  if (!takeAll(authFailures, keys).allowed) return back("throttled");
  // From here, returning without a refund records a failure.
  if (!email || !password || password.length > PASSWORD_MAX_LENGTH * 4) return back("invalid");

  try {
    const account = await findAccountForLogin(email);
    if (!account) {
      await burnPasswordCheck(password);
      return back("invalid");
    }
    if (!(await verifyPassword(password, account.passwordHash))) return back("invalid");
    refundAll(authFailures, keys);
    if (needsRehash(account.passwordHash)) await replacePasswordHash(account.id, await hashPassword(password));

    // A new session id on every sign-in; the one this browser held, if any,
    // is retired so a planted cookie cannot ride into the signed-in session.
    const previous = tokenHash(request.cookies.get(SESSION_COOKIE)?.value);
    if (previous) await deleteSession(previous);
    const token = await createSession(account.id, {
      userAgent: request.headers.get("user-agent"),
      ip: requestIp(request),
    });
    return setSessionCookie(seeOther(next), token);
  } catch (e) {
    // The server's fault, not a wrong guess.
    refundAll(authFailures, keys);
    console.error("[puls-web] sign-in failed:", e instanceof Error ? e.message : e);
    return back("unavailable");
  }
}
