// Accounts mode end to end against a real, migrated database, through the
// viewer's own route handlers and proxy.ts, connected as web_app: an invite
// creates an account and signs in, sign-in and sign-out work and rotate
// sessions, the signed-in user's reads are scoped to them, a password change
// signs other browsers out, and failed attempts are throttled. Skipped
// without the same two connection strings as webapp.integration.test.ts.

import { randomUUID } from "node:crypto";
import { NextRequest } from "next/server";
import { Client } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { newInviteToken } from "../scripts/invite.mjs";

const WEB_URL = process.env.WEB_APP_DATABASE_URL;
const ADMIN_URL = process.env.ADMIN_DATABASE_URL;
if (process.env.CI && process.env.PULS_WEB_INTEGRATION && (!WEB_URL || !ADMIN_URL)) {
  throw new Error("PULS_WEB_INTEGRATION is set but WEB_APP_DATABASE_URL or ADMIN_DATABASE_URL is missing");
}

const A = randomUUID();
const B = randomUUID();
const EMAIL = `${A.slice(0, 8)}@example.com`;
const OTHER_EMAIL = `${B.slice(0, 8)}@example.com`;
const OTHER_PASSWORD = "the other person's passphrase";
const PASSWORD = "a long enough passphrase";
const COOKIE = "__Host-puls-session";
const ORIGIN = "https://viewer.example";

// A browser behind the TLS proxy: one client address per test, so the shared
// failure limiter's buckets do not leak between tests.
function post(path: string, fields: Record<string, string>, opts: { cookie?: string; ip?: string } = {}) {
  const body = new FormData();
  for (const [k, v] of Object.entries(fields)) body.set(k, v);
  const headers = new Headers({
    host: "viewer.example",
    origin: ORIGIN,
    "x-forwarded-proto": "https",
    "x-forwarded-for": opts.ip ?? "198.51.100.1",
    "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15",
  });
  if (opts.cookie) headers.set("cookie", `${COOKIE}=${opts.cookie}`);
  return new NextRequest(new URL(path, "http://web:3000"), { method: "POST", headers, body });
}

function sessionCookie(res: Response): string | undefined {
  const match = /__Host-puls-session=([^;]*)/.exec(res.headers.get("set-cookie") ?? "");
  return match?.[1] || undefined;
}

describe.skipIf(!WEB_URL || !ADMIN_URL)("accounts mode (integration)", () => {
  let admin: Client;
  const workoutA = randomUUID();
  const workoutB = randomUUID();
  let inviteToken: string;
  let loginRoute: typeof import("@/app/api/auth/login/route");
  let logoutRoute: typeof import("@/app/api/auth/logout/route");
  let inviteRoute: typeof import("@/app/api/auth/invite/route");
  let passwordRoute: typeof import("@/app/api/auth/password/route");
  let sessionsRoute: typeof import("@/app/api/auth/sessions/route");
  let session: typeof import("./accounts/session");

  beforeAll(async () => {
    process.env.WEB_ACCOUNTS = "true";
    process.env.TRUST_PROXY_HEADERS = "true";
    process.env.DATABASE_URL = WEB_URL;

    admin = new Client({ connectionString: ADMIN_URL });
    await admin.connect();
    for (const [user, workout] of [[A, workoutA], [B, workoutB]]) {
      await admin.query("INSERT INTO users (id) VALUES ($1)", [user]);
      await admin.query(
        `INSERT INTO workouts (uuid, activity_type, start_ts, end_ts, user_id)
         VALUES ($1, 'running', now() - interval '2 hours', now() - interval '1 hour', $2)`,
        [workout, user],
      );
    }
    const invite = newInviteToken();
    inviteToken = invite.token;
    await admin.query(
      `INSERT INTO auth.invites (token_hash, user_id, email, expires_at) VALUES ($1, $2, $3, now() + interval '1 hour')`,
      [invite.hash, A, EMAIL],
    );

    // User B gets an account straight away, for the tests that need a second one.
    const { hashPassword } = await import("./accounts/password");
    await admin.query("INSERT INTO auth.accounts (user_id, email, password_hash) VALUES ($1, $2, $3)", [
      B, OTHER_EMAIL, await hashPassword(OTHER_PASSWORD),
    ]);

    loginRoute = await import("@/app/api/auth/login/route");
    logoutRoute = await import("@/app/api/auth/logout/route");
    inviteRoute = await import("@/app/api/auth/invite/route");
    passwordRoute = await import("@/app/api/auth/password/route");
    sessionsRoute = await import("@/app/api/auth/sessions/route");
    session = await import("./accounts/session");
  });

  afterAll(async () => {
    await (await import("./db")).getPool()?.end();
    if (!admin) return;
    await admin.query("DELETE FROM auth.invites WHERE user_id = ANY($1)", [[A, B]]);
    await admin.query("DELETE FROM auth.accounts WHERE user_id = ANY($1)", [[A, B]]);
    await admin.query("DELETE FROM workouts WHERE user_id = ANY($1)", [[A, B]]);
    await admin.query("DELETE FROM users WHERE id = ANY($1)", [[A, B]]);
    await admin.end();
  });

  let browser: string | undefined;

  it("accepts an invite: creates the account and signs the browser in", async () => {
    const short = await inviteRoute.POST(post("/api/auth/invite", { token: inviteToken, password: "short", confirm: "short" }, { ip: "198.51.100.10" }));
    expect(short.headers.get("location")).toBe(`/invite/${inviteToken}?error=short`);

    const res = await inviteRoute.POST(
      post("/api/auth/invite", { token: inviteToken, password: PASSWORD, confirm: PASSWORD }, { ip: "198.51.100.10" }),
    );
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("/?notice=welcome");
    browser = sessionCookie(res);
    expect(browser).toBeTruthy();
    expect(res.headers.get("set-cookie")).toMatch(/HttpOnly/i);
    expect(res.headers.get("set-cookie")).toMatch(/Secure/i);
    expect(res.headers.get("set-cookie")).toMatch(/SameSite=lax/i);

    const found = await session.findSession(browser);
    expect(found).toMatchObject({ userId: A, email: EMAIL });

    // Spent: the same link does nothing a second time.
    const again = await inviteRoute.POST(
      post("/api/auth/invite", { token: inviteToken, password: PASSWORD, confirm: PASSWORD }, { ip: "198.51.100.10" }),
    );
    expect(again.headers.get("location")).toBe(`/invite/${inviteToken}?error=invalid`);
  });

  it("reads only the signed-in user's rows, whatever the query asks", async () => {
    const { scoped } = await import("./db");
    const found = await session.findSession(browser);
    const rows = await scoped(found!.userId, (q) => q<{ uuid: string }>("SELECT uuid::text FROM workouts"));
    expect(rows.map((r) => r.uuid)).toEqual([workoutA]);
    const asked = await scoped(found!.userId, (q) => q("SELECT 1 FROM workouts WHERE uuid = $1::uuid", [workoutB]));
    expect(asked).toEqual([]);
  });

  it("lets proxy.ts through with the cookie, and not without", async () => {
    const { default: proxy } = await import("@/proxy");
    const page = (cookie?: string) => {
      const headers = new Headers({ host: "viewer.example", "x-forwarded-proto": "https" });
      if (cookie) headers.set("cookie", `${COOKIE}=${cookie}`);
      return new NextRequest(new URL("/workouts", "http://web:3000"), { headers });
    };
    expect((await proxy(page(browser))).headers.get("x-middleware-next")).toBe("1");
    expect((await proxy(page())).headers.get("location")).toBe("https://viewer.example/login?next=%2Fworkouts");
  });

  it("signs in with the right password only, and never says which half was wrong", async () => {
    const wrong = await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: "not the password", next: "/data" }, { ip: "198.51.100.20" }));
    expect(wrong.headers.get("location")).toBe("/login?error=invalid&next=%2Fdata");
    expect(sessionCookie(wrong)).toBeUndefined();
    const nobody = await loginRoute.POST(post("/api/auth/login", { email: "nobody@example.com", password: PASSWORD }, { ip: "198.51.100.20" }));
    expect(nobody.headers.get("location")).toBe("/login?error=invalid");

    // Mixed case and spaces in the address are the same account; `next` is kept
    // to this origin.
    const ok = await loginRoute.POST(
      post("/api/auth/login", { email: ` ${EMAIL.toUpperCase()} `, password: PASSWORD, next: "https://evil.example/" }, { ip: "198.51.100.20" }),
    );
    expect(ok.headers.get("location")).toBe("/");
    expect(sessionCookie(ok)).toBeTruthy();
  });

  it("gives a new session on sign-in and retires the one the browser held", async () => {
    const res = await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: PASSWORD }, { cookie: browser, ip: "198.51.100.21" }));
    const fresh = sessionCookie(res);
    expect(fresh).toBeTruthy();
    expect(fresh).not.toBe(browser);
    expect(await session.findSession(browser)).toBeNull();
    browser = fresh;
  });

  it("changes the password only with the current one, and signs other browsers out", async () => {
    const other = sessionCookie(await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: PASSWORD }, { ip: "198.51.100.30" })));
    expect(await session.findSession(other)).not.toBeNull();

    const next = "another long passphrase";
    const wrong = await passwordRoute.POST(
      post("/api/auth/password", { current: "nope nope nope", password: next, confirm: next }, { cookie: browser, ip: "198.51.100.31" }),
    );
    expect(wrong.headers.get("location")).toBe("/account?error=current");

    const ok = await passwordRoute.POST(
      post("/api/auth/password", { current: PASSWORD, password: next, confirm: next }, { cookie: browser, ip: "198.51.100.31" }),
    );
    expect(ok.headers.get("location")).toBe("/account?notice=password");
    expect(await session.findSession(other)).toBeNull();
    // This browser's session is replaced too: a copy of its old cookie is dead.
    const rotated = sessionCookie(ok);
    expect(rotated).toBeTruthy();
    expect(await session.findSession(browser)).toBeNull();
    expect(await session.findSession(rotated)).not.toBeNull();
    browser = rotated;

    const old = await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: PASSWORD }, { ip: "198.51.100.32" }));
    expect(old.headers.get("location")).toBe("/login?error=invalid");
    const fresh = await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: next }, { ip: "198.51.100.32" }));
    expect(sessionCookie(fresh)).toBeTruthy();
  });

  it("signs other browsers out from the session list", async () => {
    const found = await session.findSession(browser);
    const before = await session.listSessions(found!.accountId, found!.id);
    expect(before.length).toBeGreaterThan(1);
    expect(before.filter((s) => s.current)).toHaveLength(1);
    const res = await sessionsRoute.POST(post("/api/auth/sessions", { session: "others" }, { cookie: browser }));
    expect(res.headers.get("location")).toBe("/account?notice=sessions");
    const after = await session.listSessions(found!.accountId, found!.id);
    expect(after.map((s) => s.current)).toEqual([true]);
  });

  it("signs out: the session row goes, so a copy of the cookie stops working", async () => {
    const res = await logoutRoute.POST(post("/api/auth/logout", {}, { cookie: browser }));
    expect(res.headers.get("location")).toBe("/login?notice=signed-out");
    expect(res.headers.get("set-cookie")).toMatch(/Max-Age=0/i);
    expect(await session.findSession(browser)).toBeNull();
  });

  it("lets no more guesses through a parallel burst than the bucket holds", async () => {
    // All in flight at once, from one address, at one account: only as many
    // as the bucket holds may reach the password check — the right password
    // among them included, whatever its place.
    const attempts = Array.from({ length: 30 }, (_, i) =>
      loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: i === 29 ? "another long passphrase" : `parallel ${i} guess` }, { ip: "198.51.100.50" })),
    );
    const outcomes = (await Promise.all(attempts)).map((r) => r.headers.get("location"));
    const evaluated = outcomes.filter((l) => l !== "/login?error=throttled");
    expect(evaluated.length).toBeLessThanOrEqual(10);
    expect(outcomes.filter((l) => l === "/login?error=throttled").length).toBeGreaterThanOrEqual(20);
  });

  it("charges nothing for a successful sign-in", async () => {
    // Twenty in a row from one address: none is a failure, so none is refused.
    // (A fresh email bucket: the parallel test above spent the shared one.)
    for (let i = 0; i < 12; i++) {
      const res = await loginRoute.POST(post("/api/auth/login", { email: OTHER_EMAIL, password: OTHER_PASSWORD }, { ip: "198.51.100.60" }));
      expect(res.headers.get("location"), `attempt ${i}`).toBe("/");
    }
  });

  it("does not let an invite issued before an account was disabled bring it back", async () => {
    const stale = newInviteToken();
    await admin.query(
      `INSERT INTO auth.invites (token_hash, user_id, email, created_at, expires_at)
       VALUES ($1, $2, $3, now() - interval '1 minute', now() + interval '1 hour')`,
      [stale.hash, B, OTHER_EMAIL],
    );
    await admin.query("UPDATE auth.accounts SET disabled_at = now() WHERE user_id = $1", [B]);
    const res = await inviteRoute.POST(
      post("/api/auth/invite", { token: stale.token, password: "a brand new passphrase", confirm: "a brand new passphrase" }, { ip: "198.51.100.70" }),
    );
    expect(res.headers.get("location")).toBe(`/invite/${stale.token}?error=invalid`);
    const login = await loginRoute.POST(post("/api/auth/login", { email: OTHER_EMAIL, password: OTHER_PASSWORD }, { ip: "198.51.100.71" }));
    expect(login.headers.get("location")).toBe("/login?error=invalid");

    // A newer invite is the operator's way back in.
    const fresh = newInviteToken();
    await admin.query(
      `INSERT INTO auth.invites (token_hash, user_id, email, created_at, expires_at)
       VALUES ($1, $2, $3, now() + interval '1 second', now() + interval '1 hour')`,
      [fresh.hash, B, OTHER_EMAIL],
    );
    const back = await inviteRoute.POST(
      post("/api/auth/invite", { token: fresh.token, password: OTHER_PASSWORD, confirm: OTHER_PASSWORD }, { ip: "198.51.100.72" }),
    );
    expect(back.headers.get("location")).toBe("/?notice=welcome");
  });

  it("retires the session a browser held when it accepts an invite", async () => {
    const held = sessionCookie(await loginRoute.POST(post("/api/auth/login", { email: OTHER_EMAIL, password: OTHER_PASSWORD }, { ip: "198.51.100.80" })));
    expect(await session.findSession(held)).not.toBeNull();
    const reset = newInviteToken();
    await admin.query(
      `INSERT INTO auth.invites (token_hash, user_id, email, expires_at) VALUES ($1, $2, $3, now() + interval '1 hour')`,
      [reset.hash, B, OTHER_EMAIL],
    );
    const res = await inviteRoute.POST(
      post("/api/auth/invite", { token: reset.token, password: OTHER_PASSWORD, confirm: OTHER_PASSWORD }, { cookie: held, ip: "198.51.100.81" }),
    );
    expect(res.headers.get("location")).toBe("/?notice=welcome");
    expect(await session.findSession(held)).toBeNull();
  });

  it("throttles one address, and one account from many addresses, before checking the password", async () => {
    for (let i = 0; i < 10; i++) {
      await loginRoute.POST(post("/api/auth/login", { email: `nobody${i}@example.com`, password: "x".repeat(12) }, { ip: "198.51.100.40" }));
    }
    const sprayed = await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: "another long passphrase" }, { ip: "198.51.100.40" }));
    expect(sprayed.headers.get("location")).toBe("/login?error=throttled");

    for (let i = 0; i < 10; i++) {
      await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: `guess number ${i}` }, { ip: `203.0.113.${i + 1}` }));
    }
    const right = await loginRoute.POST(post("/api/auth/login", { email: EMAIL, password: "another long passphrase" }, { ip: "203.0.113.99" }));
    expect(right.headers.get("location")).toBe("/login?error=throttled");
  });
});
