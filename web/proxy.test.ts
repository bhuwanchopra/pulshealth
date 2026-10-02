import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The session store is the database; here it is whatever each test says.
const findSession = vi.hoisted(() => vi.fn());
vi.mock("@/lib/accounts/session", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/accounts/session")>();
  return { ...actual, findSession };
});

const TOKEN = "A".repeat(43);
const SESSION = {
  id: Buffer.alloc(32),
  accountId: "acc",
  userId: "11111111-1111-4111-8111-111111111111",
  email: "a@example.com",
  isAdmin: false,
  refreshed: false,
};

function request(path: string, init: { method?: string; headers?: Record<string, string>; cookie?: string; base?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.cookie) headers.set("cookie", init.cookie);
  return new NextRequest(new URL(path, init.base ?? "http://web:3000"), { method: init.method ?? "GET", headers });
}

// What a request through a TLS proxy (TRUST_PROXY_HEADERS=true) looks like.
const viaProxy = { host: "viewer.example", "x-forwarded-proto": "https", "x-forwarded-for": "203.0.113.5" };
const passed = (res: Response) => res.headers.get("x-middleware-next") === "1";

const saved = { ...process.env };
beforeEach(() => {
  findSession.mockReset();
  vi.stubEnv("NODE_ENV", "production");
  delete process.env.WEB_AUTH_PASSWORD;
  delete process.env.WEB_ACCOUNTS;
  delete process.env.TRUST_PROXY_HEADERS;
  delete process.env.WEB_PUBLIC_URL;
});
afterEach(() => {
  vi.unstubAllEnvs();
  process.env = { ...saved };
});

async function proxy(req: NextRequest) {
  const { default: run } = await import("./proxy");
  return run(req);
}

describe("every mode", () => {
  it("sends a nonce'd Content-Security-Policy and hands the nonce to the page", async () => {
    const res = await proxy(request("/"));
    const csp = res.headers.get("content-security-policy")!;
    const nonce = /'nonce-([^']+)'/.exec(csp)?.[1];
    expect(nonce).toBeTruthy();
    expect(res.headers.get("x-middleware-request-x-nonce")).toBe(nonce);
  });
});

describe("open and basic mode (unchanged)", () => {
  it("serves everything when no password is set", async () => {
    expect(passed(await proxy(request("/workouts")))).toBe(true);
  });

  it("challenges without the password and serves with it", async () => {
    process.env.WEB_AUTH_PASSWORD = "pw";
    const challenged = await proxy(request("/"));
    expect(challenged.status).toBe(401);
    expect(challenged.headers.get("www-authenticate")).toContain("Basic");
    const auth = `Basic ${btoa("any:pw")}`;
    expect(passed(await proxy(request("/", { headers: { authorization: auth } })))).toBe(true);
    expect(passed(await proxy(request("/api/healthz")))).toBe(true);
  });

  it("still turns ?user= into the cookie", async () => {
    const res = await proxy(request("/workouts?user=22222222-2222-4222-8222-222222222222"));
    expect(res.status).toBe(303);
    expect(res.cookies.get("puls-user")?.value).toBe("22222222-2222-4222-8222-222222222222");
  });
});

describe("accounts mode", () => {
  beforeEach(() => {
    process.env.WEB_ACCOUNTS = "true";
    process.env.TRUST_PROXY_HEADERS = "true";
  });

  it("answers the health check over plain HTTP, and nothing else", async () => {
    delete process.env.TRUST_PROXY_HEADERS;
    expect(passed(await proxy(request("/api/healthz")))).toBe(true);
    expect(passed(await proxy(request("/_next/static/chunks/main.js")))).toBe(true);
    expect((await proxy(request("/login"))).status).toBe(403);
    expect((await proxy(request("/"))).status).toBe(403);
    expect(findSession).not.toHaveBeenCalled();
  });

  it("does not believe X-Forwarded-Proto unless told to", async () => {
    delete process.env.TRUST_PROXY_HEADERS;
    expect((await proxy(request("/login", { headers: viaProxy }))).status).toBe(403);
  });

  it("serves the sign-in and invite pages without a session", async () => {
    expect(passed(await proxy(request("/login", { headers: viaProxy })))).toBe(true);
    expect(passed(await proxy(request(`/invite/${TOKEN}`, { headers: viaProxy })))).toBe(true);
    expect(findSession).not.toHaveBeenCalled();
  });

  it("sends a page load without a session to sign in, remembering where it was going", async () => {
    findSession.mockResolvedValue(null);
    const res = await proxy(request("/workouts?range=W&_rsc=x1", { headers: viaProxy }));
    expect(res.status).toBe(303);
    // Absolute (Next.js refuses a relative Location from the proxy), on the
    // origin the browser used rather than the container's own host.
    expect(res.headers.get("location")).toBe("https://viewer.example/login?next=%2Fworkouts%3Frange%3DW");
    expect((await proxy(request("/", { headers: viaProxy }))).headers.get("location")).toBe("https://viewer.example/login");
    process.env.WEB_PUBLIC_URL = "https://app.example/";
    expect((await proxy(request("/", { headers: viaProxy }))).headers.get("location")).toBe("https://app.example/login");
  });

  it("answers 401, not a redirect, to API calls and posts without a session", async () => {
    findSession.mockResolvedValue(null);
    expect((await proxy(request("/api/user", { headers: viaProxy }))).status).toBe(401);
    const post = request("/api/auth/password", { method: "POST", headers: { ...viaProxy, origin: "https://viewer.example" } });
    expect((await proxy(post)).status).toBe(401);
  });

  it("drops a cookie that names no live session", async () => {
    findSession.mockResolvedValue(null);
    const res = await proxy(request("/", { headers: viaProxy, cookie: `__Host-puls-session=${TOKEN}` }));
    expect(res.status).toBe(303);
    const cleared = res.cookies.get("__Host-puls-session");
    expect(cleared?.value).toBe("");
    expect(cleared?.maxAge).toBe(0);
  });

  it("serves a live session, checking it against the store and sliding it", async () => {
    findSession.mockResolvedValue({ ...SESSION, refreshed: true });
    const res = await proxy(request("/workouts", { headers: viaProxy, cookie: `__Host-puls-session=${TOKEN}` }));
    expect(passed(res)).toBe(true);
    expect(findSession).toHaveBeenCalledWith(TOKEN, true);
    const cookie = res.cookies.get("__Host-puls-session");
    expect(cookie).toMatchObject({ value: TOKEN, secure: true, httpOnly: true, sameSite: "lax", path: "/" });
  });

  it("ignores ?user= entirely", async () => {
    findSession.mockResolvedValue(SESSION);
    const res = await proxy(
      request("/workouts?user=22222222-2222-4222-8222-222222222222", { headers: viaProxy, cookie: `__Host-puls-session=${TOKEN}` }),
    );
    expect(passed(res)).toBe(true);
    expect(res.cookies.get("puls-user")).toBeUndefined();
  });

  it("refuses a state-changing request from another origin, or with none", async () => {
    findSession.mockResolvedValue(SESSION);
    for (const headers of [
      { ...viaProxy, origin: "https://evil.example" },
      { ...viaProxy },
      { ...viaProxy, origin: "https://viewer.example", "sec-fetch-site": "cross-site" },
    ]) {
      const res = await proxy(request("/api/auth/login", { method: "POST", headers }));
      expect(res.status, JSON.stringify(headers)).toBe(403);
    }
    const ok = await proxy(request("/api/auth/login", { method: "POST", headers: { ...viaProxy, origin: "https://viewer.example" } }));
    expect(passed(ok)).toBe(true);
  });

  it("is a 503, never a sign-in redirect, when the session store is down", async () => {
    findSession.mockRejectedValue(new Error("connection refused"));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await proxy(request("/", { headers: viaProxy, cookie: `__Host-puls-session=${TOKEN}` }));
    expect(res.status).toBe(503);
  });

  it("ignores WEB_AUTH_PASSWORD", async () => {
    process.env.WEB_AUTH_PASSWORD = "pw";
    expect(passed(await proxy(request("/login", { headers: viaProxy })))).toBe(true);
  });
});
