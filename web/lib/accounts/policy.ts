// Which requests accounts mode lets through, and on what condition. Pure:
// proxy.ts feeds it the facts and carries out the answer, and the tests walk
// every route class through it.

export type RouteClass =
  /** The container health check: always answered, even over plain HTTP. */
  | "health"
  /** Build assets and icons the sign-in page itself needs. Nothing personal. */
  | "asset"
  /** Signing in and accepting an invite: reachable without a session. */
  | "public"
  /** Everything else: a valid session or nothing. */
  | "protected";

/** Paths reachable without a session (beyond assets and the health check). */
export const PUBLIC_PAGES = ["/login"] as const;
// Sign-out too: leaving a session that already expired should not be an
// error. Every POST, these included, still has to pass the origin check.
export const PUBLIC_API = ["/api/auth/login", "/api/auth/invite", "/api/auth/logout"] as const;

export function classifyPath(pathname: string, development = false): RouteClass {
  if (pathname === "/api/healthz") return "health";
  if (
    pathname.startsWith("/_next/static/") ||
    pathname === "/icon.svg" ||
    pathname === "/apple-icon.svg" ||
    pathname === "/favicon.ico" ||
    // The dev server's own endpoints (error overlay, HMR); absent in production.
    (development && pathname.startsWith("/__nextjs"))
  ) {
    return "asset";
  }
  if ((PUBLIC_PAGES as readonly string[]).includes(pathname)) return "public";
  if ((PUBLIC_API as readonly string[]).includes(pathname)) return "public";
  // /invite/<token>: exactly one segment, the token.
  if (/^\/invite\/[^/]+$/.test(pathname)) return "public";
  return "protected";
}

export type AccountsDecision =
  /** Serve it; no session needed. */
  | "pass"
  /** Plain HTTP outside development: refuse rather than take a password over it. */
  | "insecure"
  /** A state-changing request from another origin. */
  | "cross-origin"
  /** Serve it only to a valid session. */
  | "session";

export function decideAccounts(facts: {
  pathname: string;
  secure: boolean;
  sameOrigin: boolean;
  development: boolean;
}): AccountsDecision {
  const route = classifyPath(facts.pathname, facts.development);
  if (route === "health" || route === "asset") return "pass";
  if (!facts.secure) return "insecure";
  if (!facts.sameOrigin) return "cross-origin";
  return route === "public" ? "pass" : "session";
}

/** What a request without a valid session gets: pages go to sign-in, the rest 401. */
export function unauthenticatedAnswer(method: string, pathname: string): "redirect" | "unauthorized" {
  const navigable = method === "GET" || method === "HEAD";
  return navigable && !pathname.startsWith("/api/") ? "redirect" : "unauthorized";
}
