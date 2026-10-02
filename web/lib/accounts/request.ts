// What accounts mode needs to know about a request, from its URL and headers
// alone. Pure, so proxy.ts and the route handlers share one implementation
// and the tests need no server.

import type { Env } from "../mode";

/** The first comma-separated value of a header, trimmed; null if absent or empty. */
export function firstValue(header: string | null | undefined): string | null {
  const first = header?.split(",")[0]?.trim();
  return first ? first : null;
}

/**
 * The header that carries the client's address when proxy headers are
 * trusted: `x-forwarded-for` (its first entry — right for a proxy that
 * overwrites it, such as Tailscale Serve), `cf-connecting-ip` (Cloudflare,
 * which appends to X-Forwarded-For but always overwrites this one) or
 * `x-real-ip`. Set by WEB_CLIENT_IP_HEADER.
 */
export function clientIpHeader(env: Env = process.env): string {
  const value = (env.WEB_CLIENT_IP_HEADER ?? "").trim().toLowerCase();
  return ["cf-connecting-ip", "x-real-ip", "x-forwarded-for"].includes(value) ? value : "x-forwarded-for";
}

/**
 * The address a failed attempt is charged to. Without trusted proxy headers
 * there is none to go on — Next.js does not expose the TCP peer — so every
 * client shares one bucket; accounts mode refuses plain HTTP outside
 * development anyway, which in production means TRUST_PROXY_HEADERS is on.
 */
export function clientIp(headers: Headers, trust: boolean, headerName = clientIpHeader()): string {
  if (!trust) return "direct";
  return firstValue(headers.get(headerName)) ?? "unknown";
}

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);

/**
 * Whether the browser reached this viewer over HTTPS. The container itself
 * only ever speaks HTTP, so behind a TLS proxy this rests on
 * X-Forwarded-Proto, believed only when proxy headers are trusted. In
 * development, http://localhost counts: browsers treat it as a secure
 * context and keep Secure cookies for it.
 */
export function isSecureRequest(url: URL, headers: Headers, trust: boolean, development: boolean): boolean {
  if (url.protocol === "https:") return true;
  if (trust && firstValue(headers.get("x-forwarded-proto"))?.toLowerCase() === "https") return true;
  return development && LOCAL_HOSTS.has(url.hostname);
}

/**
 * The origin the browser is on, for an absolute redirect: WEB_PUBLIC_URL when
 * set; else, with trusted proxy headers, X-Forwarded-Proto and -Host; else
 * the URL as the container saw it.
 */
export function publicOrigin(url: URL, headers: Headers, trust: boolean, publicUrl: string | undefined): string {
  if (publicUrl) {
    try {
      return new URL(publicUrl).origin;
    } catch {
      // Malformed: fall through (instrumentation.ts warns at startup).
    }
  }
  if (trust) {
    const proto = firstValue(headers.get("x-forwarded-proto"));
    const host = firstValue(headers.get("x-forwarded-host")) ?? headers.get("host");
    if (host && (proto === "https" || proto === "http")) return `${proto}://${host}`;
  }
  return url.origin;
}

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

/** Whether a method changes state (and so needs the same-origin check). */
export function isUnsafeMethod(method: string): boolean {
  return !SAFE_METHODS.has(method.toUpperCase());
}

/**
 * The origins a state-changing request may come from: this request's own
 * (scheme, and host as the browser saw it), plus WEB_PUBLIC_URL's when set —
 * the answer for a proxy that rewrites the Host header.
 */
export function allowedOrigins(
  url: URL,
  headers: Headers,
  trust: boolean,
  _development: boolean,
  publicUrl: string | undefined,
): Set<string> {
  const origins = new Set<string>();
  const host = (trust && firstValue(headers.get("x-forwarded-host"))) || headers.get("host") || url.host;
  // The scheme the browser used: https behind a trusted TLS proxy (and then
  // only https — a plain-http Origin for the same host is someone else),
  // else what the container saw.
  const forwardedHttps = trust && firstValue(headers.get("x-forwarded-proto"))?.toLowerCase() === "https";
  origins.add(`${forwardedHttps ? "https:" : url.protocol}//${host}`.toLowerCase());
  if (publicUrl) {
    try {
      origins.add(new URL(publicUrl).origin.toLowerCase());
    } catch {
      // A malformed WEB_PUBLIC_URL adds nothing; instrumentation.ts says so.
    }
  }
  return origins;
}

/**
 * Cross-site request forgery check for a state-changing request: the
 * browser must say where the request came from (Origin, which every current
 * browser sends with a POST) and it must be this viewer; a Sec-Fetch-Site
 * other than same-origin is refused outright. SameSite=Lax on the session
 * cookie is the second lock, not the only one.
 */
export function isSameOriginRequest(
  method: string,
  url: URL,
  headers: Headers,
  trust: boolean,
  development: boolean,
  publicUrl: string | undefined,
): boolean {
  if (!isUnsafeMethod(method)) return true;
  const site = headers.get("sec-fetch-site");
  if (site !== null && site !== "same-origin") return false;
  const origin = headers.get("origin");
  if (!origin || origin === "null") return false;
  return allowedOrigins(url, headers, trust, development, publicUrl).has(origin.toLowerCase());
}
