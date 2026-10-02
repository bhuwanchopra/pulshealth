// Response headers that harden every page, in every mode.
//
// The static ones (HSTS, Referrer-Policy, …) are set in next.config.ts. The
// Content-Security-Policy is built here per request, because it carries a
// fresh nonce: proxy.ts sets it on the request (Next.js reads the nonce from
// there and stamps it on its own scripts) and on the response, and the root
// layout puts the same nonce on its one inline script. No inline script runs
// without it; `strict-dynamic` lets the nonce'd bundles load their chunks.

import { MAP_STYLES } from "./mapStyles";

/** A fresh, unguessable nonce for one response. */
export function newNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes));
}

/**
 * The tile servers the route map draws from, as CSP sources, derived from
 * lib/mapStyles.ts so a new basemap cannot be blocked by a stale list.
 * `{s}` subdomain placeholders become a wildcard.
 */
export function tileImageSources(): string[] {
  const sources = new Set<string>();
  for (const style of MAP_STYLES) {
    const match = style.spec?.url.match(/^https:\/\/[^/]+/);
    if (match) sources.add(match[0].replace("{s}", "*"));
  }
  return [...sources].sort();
}

export function contentSecurityPolicy(nonce: string, development: boolean): string {
  return [
    "default-src 'self'",
    // React needs eval in development only (error stacks); never in production.
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${development ? " 'unsafe-eval'" : ""}`,
    // Inline style attributes are everywhere (React style props, Leaflet), and
    // a nonce here would switch 'unsafe-inline' off; styles cannot run code.
    "style-src 'self' 'unsafe-inline'",
    ["img-src 'self' data: blob:", ...tileImageSources()].join(" "),
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join("; ");
}

/** The headers next.config.ts sets on every response. */
export const STATIC_SECURITY_HEADERS: { key: string; value: string }[] = [
  // Ignored by browsers over plain HTTP (a LAN install), honoured over HTTPS.
  // No includeSubDomains: a self-hoster's other hosts are not ours to pin.
  { key: "Strict-Transport-Security", value: "max-age=31536000" },
  // Paths carry workout ids and one-time invite tokens; no other site needs
  // them. (The route map's tile requests opt back in to sending the origin.)
  { key: "Referrer-Policy", value: "same-origin" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  // frame-ancestors 'none' in the CSP, for browsers that predate it.
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
];
